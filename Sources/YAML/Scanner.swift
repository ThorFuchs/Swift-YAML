// SPDX-License-Identifier: Apache-2.0
// Token-level scanner. The structure (simple-key bookkeeping, indentation stack,
// token queue) follows the classic libyaml/PyYAML design, adapted to YAML 1.2 rules.

enum ScalarStyle: Sendable, Equatable { case plain, singleQuoted, doubleQuoted, literal, folded }

enum TagSpec: Sendable, Equatable {
    /// `!<tag:yaml.org,2002:str>`
    case verbatim(String)
    /// A lone `!`.
    case nonSpecific
    /// `!!str`, `!local`, `!e!suffix`.
    case shorthand(handle: String, suffix: String)
}

enum TokenKind: Sendable, Equatable {
    case streamStart, streamEnd
    case versionDirective(major: Int, minor: Int)
    case tagDirective(handle: String, prefix: String)
    case documentStart, documentEnd
    case blockSequenceStart, blockMappingStart, blockEnd
    case flowSequenceStart, flowSequenceEnd, flowMappingStart, flowMappingEnd
    case blockEntry, flowEntry, key, value
    case alias(String), anchor(String), tag(TagSpec)
    case scalar(String, ScalarStyle)

    var name: String {
        switch self {
        case .streamStart: "start of stream"
        case .streamEnd: "end of stream"
        case .versionDirective: "%YAML directive"
        case .tagDirective: "%TAG directive"
        case .documentStart: "'---'"
        case .documentEnd: "'...'"
        case .blockSequenceStart: "start of block sequence"
        case .blockMappingStart: "start of block mapping"
        case .blockEnd: "end of block collection"
        case .flowSequenceStart: "'['"
        case .flowSequenceEnd: "']'"
        case .flowMappingStart: "'{'"
        case .flowMappingEnd: "'}'"
        case .blockEntry: "'-'"
        case .flowEntry: "','"
        case .key: "'?'"
        case .value: "':'"
        case .alias: "alias"
        case .anchor: "anchor"
        case .tag: "tag"
        case .scalar: "scalar"
        }
    }
}

struct Token: Sendable {
    var kind: TokenKind
    var start: Mark
}

private struct SimpleKey {
    var tokenNumber: Int
    var required: Bool
    var mark: Mark
    /// The whitespace before the key contained a tab.
    var tabbed: Bool
}

/// Decodes UTF-8 and rejects characters outside YAML's printable set (c-printable).
func decodeYAMLInput(_ bytes: [UInt8]) throws(YAMLError) -> [Unicode.Scalar] {
    var scalars: [Unicode.Scalar] = []
    scalars.reserveCapacity(bytes.count)
    var decoder = UTF8()
    var iterator = bytes.makeIterator()
    var line = 0, column = 0
    loop: while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar):
            let v = scalar.value
            let printable = v == 0x09 || v == 0x0A || v == 0x0D || (0x20...0x7E).contains(v) || v == 0x85
                || (0xA0...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
            guard printable else {
                throw YAMLError(.invalidEncoding, "character U+\(String(v, radix: 16, uppercase: true)) is not allowed in YAML",
                                line: line + 1, column: column + 1)
            }
            scalars.append(scalar)
            if v == 0x0A { line += 1; column = 0 } else { column += 1 }
        case .emptyInput:
            break loop
        case .error:
            throw YAMLError(.invalidEncoding, "input is not valid UTF-8", line: line + 1, column: column + 1)
        }
    }
    return scalars
}

private let flowIndicators: Set<Unicode.Scalar> = [",", "[", "]", "{", "}"]

struct Scanner {
    private let s: [Unicode.Scalar]
    private var index = 0
    private var line = 0
    private var column = 0

    private var done = false
    private var flowLevel = 0
    private var tokens: [Token] = []
    private var head = 0
    private var tokensTaken = 0
    private var indent = -1
    private var indents: [Int] = []
    private var allowSimpleKey = true
    private var possibleSimpleKeys: [SimpleKey?] = [nil]
    /// The whitespace just before the current token contained a tab.
    private var tabBeforeToken = false
    /// The previous token was a quoted scalar or a flow collection end, so `:` may follow it directly in flow.
    private var lastTokenJSONLike = false
    /// The previous token could have been an implicit key (scalar, alias, flow collection end).
    private var lastTokenKeyLike = false

    init(_ scalars: [Unicode.Scalar]) {
        s = scalars
        tokens.append(Token(kind: .streamStart, start: .start))
    }

    // MARK: Token queue

    mutating func peekToken() throws(YAMLError) -> Token {
        while needMoreTokens() { try fetchNextToken() }
        return tokens[head]
    }

    mutating func nextToken() throws(YAMLError) -> Token {
        let token = try peekToken()
        head += 1
        tokensTaken += 1
        if head > 512 && head * 2 > tokens.count {
            tokens.removeFirst(head)
            head = 0
        }
        return token
    }

    private mutating func needMoreTokens() -> Bool {
        if done { return false }
        if head == tokens.count { return true }
        staleSimpleKeysQuietly()
        return nextPossibleSimpleKey() == tokensTaken
    }

    private func nextPossibleSimpleKey() -> Int? {
        var minimum: Int?
        for key in possibleSimpleKeys {
            if let key, minimum.map({ key.tokenNumber < $0 }) ?? true { minimum = key.tokenNumber }
        }
        return minimum
    }

    private var mark: Mark { Mark(index: index, line: line, column: column) }

    private func error(_ message: String, _ at: Mark? = nil) -> YAMLError {
        YAMLError(.syntax, message, at: at ?? mark)
    }

    private mutating func append(_ kind: TokenKind, _ start: Mark) {
        tokens.append(Token(kind: kind, start: start))
    }

    // MARK: Character helpers

    private func peek(_ k: Int = 0) -> Unicode.Scalar {
        index + k < s.count ? s[index + k] : "\0"
    }

    private var atEnd: Bool { index >= s.count }

    private static func isBreak(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }
    private static func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
    private func isBreakOrEnd(_ k: Int = 0) -> Bool { index + k >= s.count || Self.isBreak(s[index + k]) }
    private func isBlankOrBreakOrEnd(_ k: Int = 0) -> Bool { isBreakOrEnd(k) || Self.isBlank(s[index + k]) }

    private mutating func forward(_ n: Int = 1) {
        for _ in 0..<n where index < s.count {
            let c = s[index]
            index += 1
            if c == "\n" || (c == "\r" && peek() != "\n") {
                line += 1; column = 0
            } else {
                column += 1
            }
        }
    }

    /// Consumes one line break and returns "\n", or returns "" when there is none.
    private mutating func scanLineBreak() -> String {
        if peek() == "\r" && peek(1) == "\n" { forward(2); return "\n" }
        if Self.isBreak(peek()) { forward(); return "\n" }
        return ""
    }

    private func atDocumentMarker() -> Bool {
        guard column == 0, index + 2 < s.count else { return false }
        let a = s[index], b = s[index + 1], c = s[index + 2]
        guard (a == "-" && b == "-" && c == "-") || (a == "." && b == "." && c == ".") else { return false }
        return isBlankOrBreakOrEnd(3)
    }

    /// Whether only blanks precede the current position on its line.
    private func firstOnLine() -> Bool {
        var j = index - 1
        while j >= index - column && j >= 0 {
            if !Self.isBlank(s[j]) { return false }
            j -= 1
        }
        return true
    }

    /// Leading spaces (not tabs) of the current line.
    private func lineIndentSpaces() -> Int {
        var j = index - column
        while j < index && s[j] == " " { j += 1 }
        return j - (index - column)
    }

    private func checkDocumentStart() -> Bool { atDocumentMarker() && peek() == "-" }
    private func checkDocumentEnd() -> Bool { atDocumentMarker() && peek() == "." }

    private func substring(_ length: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[index..<min(index + length, s.count)])
        return String(view)
    }

    // MARK: Fetching

    private mutating func fetchNextToken() throws(YAMLError) {
        try scanToNextToken()
        try staleSimpleKeys()
        let jsonLike = lastTokenJSONLike
        let keyLike = lastTokenKeyLike
        lastTokenJSONLike = false
        lastTokenKeyLike = false
        if !atEnd && firstOnLine() {
            let spaces = lineIndentSpaces()
            if flowLevel > 0 && spaces <= indent {
                throw error("flow content must be indented more than the enclosing block")
            }
            if flowLevel == 0 && tabBeforeToken && spaces <= indent {
                throw error("tab characters must not be used for indentation")
            }
        }
        unwindIndent(column)
        if atEnd { fetchStreamEnd(); return }
        let c = peek()
        if column == 0 && c == "%" { try fetchDirective(); return }
        if c == "-" && checkDocumentStart() { try fetchDocumentIndicator(.documentStart); return }
        if c == "." && checkDocumentEnd() { try fetchDocumentIndicator(.documentEnd); return }
        switch c {
        case "[": try fetchFlowCollectionStart(.flowSequenceStart); return
        case "{": try fetchFlowCollectionStart(.flowMappingStart); return
        case "]": try fetchFlowCollectionEnd(.flowSequenceEnd); return
        case "}": try fetchFlowCollectionEnd(.flowMappingEnd); return
        case ",": try fetchFlowEntry(); return
        default: break
        }
        if c == "-" && isBlankOrBreakOrEnd(1) { try fetchBlockEntry(); return }
        if c == "?" && isBlankOrBreakOrEnd(1) { try fetchKey(); return }
        if c == ":" && checkValue(jsonLike: jsonLike) { try fetchValue(keyLike: keyLike); return }
        switch c {
        case "*": try fetchAnchor(alias: true); return
        case "&": try fetchAnchor(alias: false); return
        case "!": try fetchTag(); return
        case "|" where flowLevel == 0: try fetchBlockScalar(folded: false); return
        case ">" where flowLevel == 0: try fetchBlockScalar(folded: true); return
        case "'": try fetchFlowScalar(double: false); return
        case "\"": try fetchFlowScalar(double: true); return
        default: break
        }
        if checkPlain() { try fetchPlain(); return }
        throw error("found character '\(c.escaped(asASCII: true))' that cannot start any token")
    }

    private func checkValue(jsonLike: Bool) -> Bool {
        if flowLevel > 0 {
            if jsonLike { return true }
            return isBlankOrBreakOrEnd(1) || flowIndicators.contains(peek(1))
        }
        return isBlankOrBreakOrEnd(1)
    }

    private func checkPlain() -> Bool {
        let c = peek()
        if Self.isBlank(c) || Self.isBreak(c) { return false }
        if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(c) {
            guard c == "-" || c == "?" || c == ":" else { return false }
            if isBlankOrBreakOrEnd(1) { return false }
            if flowLevel > 0 && flowIndicators.contains(peek(1)) { return false }
            return true
        }
        return true
    }

    private mutating func scanToNextToken() throws(YAMLError) {
        if index == 0 && peek() == "\u{FEFF}" { forward() }
        while true {
            var sawTab = false
            while Self.isBlank(peek()) && !atEnd {
                if peek() == "\t" { sawTab = true }
                forward()
            }
            tabBeforeToken = sawTab
            if peek() == "#" && !atEnd {
                if index > 0 && !Self.isBlank(s[index - 1]) && !Self.isBreak(s[index - 1]) {
                    throw error("comments must be separated from other tokens by whitespace")
                }
                while !isBreakOrEnd() { forward() }
            }
            if !atEnd && Self.isBreak(peek()) {
                _ = scanLineBreak()
                if flowLevel == 0 { allowSimpleKey = true }
            } else {
                return
            }
        }
    }

    // MARK: Simple keys

    private mutating func staleSimpleKeysQuietly() {
        // Same as staleSimpleKeys, but required keys are left for fetchNextToken to report.
        for level in possibleSimpleKeys.indices {
            if let key = possibleSimpleKeys[level], !key.required,
               key.mark.line != line || index - key.mark.index > 1024 {
                possibleSimpleKeys[level] = nil
            }
        }
    }

    private mutating func staleSimpleKeys() throws(YAMLError) {
        for level in possibleSimpleKeys.indices {
            if let key = possibleSimpleKeys[level], key.mark.line != line || index - key.mark.index > 1024 {
                if key.required { throw error("could not find expected ':' after implicit key", key.mark) }
                possibleSimpleKeys[level] = nil
            }
        }
    }

    private mutating func saveSimpleKey() throws(YAMLError) {
        let required = flowLevel == 0 && indent == column
        if allowSimpleKey {
            try removeSimpleKey()
            possibleSimpleKeys[flowLevel] = SimpleKey(tokenNumber: tokensTaken + tokens.count - head,
                                                      required: required, mark: mark,
                                                      tabbed: tabBeforeToken && flowLevel == 0)
        }
    }

    private mutating func removeSimpleKey() throws(YAMLError) {
        if let key = possibleSimpleKeys[flowLevel], key.required {
            throw error("could not find expected ':' after implicit key", key.mark)
        }
        possibleSimpleKeys[flowLevel] = nil
    }

    // MARK: Indentation

    private mutating func unwindIndent(_ col: Int) {
        if flowLevel > 0 { return }
        while indent > col {
            let start = mark
            indent = indents.popLast() ?? -1
            append(.blockEnd, start)
        }
    }

    private mutating func addIndent(_ col: Int) -> Bool {
        if indent < col {
            indents.append(indent)
            indent = col
            return true
        }
        return false
    }

    // MARK: Fetchers

    private mutating func fetchStreamEnd() {
        unwindIndent(-1)
        possibleSimpleKeys = Array(repeating: nil, count: possibleSimpleKeys.count)
        allowSimpleKey = false
        append(.streamEnd, mark)
        done = true
    }

    private mutating func fetchDirective() throws(YAMLError) {
        unwindIndent(-1)
        try removeSimpleKey()
        allowSimpleKey = false
        if let token = try scanDirective() { tokens.append(token) }
    }

    private mutating func fetchDocumentIndicator(_ kind: TokenKind) throws(YAMLError) {
        unwindIndent(-1)
        try removeSimpleKey()
        allowSimpleKey = false
        let start = mark
        forward(3)
        append(kind, start)
        if kind == .documentEnd {
            skipBlanks()
            guard isBreakOrEnd() || peek() == "#" else {
                throw error("only a comment may follow '...' on the same line")
            }
        }
    }

    private mutating func fetchFlowCollectionStart(_ kind: TokenKind) throws(YAMLError) {
        try saveSimpleKey()
        flowLevel += 1
        possibleSimpleKeys.append(nil)
        allowSimpleKey = true
        let start = mark
        forward()
        append(kind, start)
    }

    private mutating func fetchFlowCollectionEnd(_ kind: TokenKind) throws(YAMLError) {
        try removeSimpleKey()
        if flowLevel > 0 {
            flowLevel -= 1
            possibleSimpleKeys.removeLast()
        }
        allowSimpleKey = false
        let start = mark
        forward()
        lastTokenJSONLike = true
        lastTokenKeyLike = true
        append(kind, start)
    }

    private mutating func fetchFlowEntry() throws(YAMLError) {
        allowSimpleKey = true
        try removeSimpleKey()
        let start = mark
        forward()
        append(.flowEntry, start)
    }

    private func checkNoTabBeforeIndicator() throws(YAMLError) {
        if flowLevel == 0 && tabBeforeToken {
            throw error("a tab must not separate block indicators")
        }
    }

    private mutating func fetchBlockEntry() throws(YAMLError) {
        if flowLevel == 0 {
            try checkNoTabBeforeIndicator()
            if !allowSimpleKey { throw error("block sequence entries are not allowed here") }
            if addIndent(column) { append(.blockSequenceStart, mark) }
        }
        allowSimpleKey = true
        try removeSimpleKey()
        let start = mark
        forward()
        append(.blockEntry, start)
    }

    private mutating func fetchKey() throws(YAMLError) {
        if flowLevel == 0 {
            try checkNoTabBeforeIndicator()
            if !allowSimpleKey { throw error("mapping keys are not allowed here") }
            if addIndent(column) { append(.blockMappingStart, mark) }
        }
        allowSimpleKey = flowLevel == 0
        try removeSimpleKey()
        let start = mark
        forward()
        append(.key, start)
    }

    private mutating func fetchValue(keyLike: Bool) throws(YAMLError) {
        if let key = possibleSimpleKeys[flowLevel] {
            possibleSimpleKeys[flowLevel] = nil
            let position = head + key.tokenNumber - tokensTaken
            tokens.insert(Token(kind: .key, start: key.mark), at: position)
            if flowLevel == 0 && key.mark.column > indent && key.tabbed {
                throw error("a tab must not separate block indicators", key.mark)
            }
            if flowLevel == 0 && addIndent(key.mark.column) {
                tokens.insert(Token(kind: .blockMappingStart, start: key.mark), at: position)
            }
            allowSimpleKey = false
        } else {
            if flowLevel == 0 {
                if !allowSimpleKey || (keyLike && !firstOnLine()) {
                    throw error("mapping values are not allowed here (an implicit key must be on one line)")
                }
                if addIndent(column) { append(.blockMappingStart, mark) }
            }
            allowSimpleKey = flowLevel == 0
            try removeSimpleKey()
        }
        let start = mark
        forward()
        append(.value, start)
    }

    private mutating func fetchAnchor(alias: Bool) throws(YAMLError) {
        try saveSimpleKey()
        allowSimpleKey = false
        let start = mark
        forward()
        var length = 0
        while !isBlankOrBreakOrEnd(length) && !flowIndicators.contains(peek(length)) { length += 1 }
        guard length > 0 else { throw error("\(alias ? "alias" : "anchor") name must not be empty", start) }
        let name = substring(length)
        forward(length)
        if alias { lastTokenKeyLike = true }
        append(alias ? .alias(name) : .anchor(name), start)
    }

    private mutating func fetchTag() throws(YAMLError) {
        try saveSimpleKey()
        allowSimpleKey = false
        let start = mark
        let spec: TagSpec
        if peek(1) == "<" {
            forward(2)
            let uri = try scanTagURI(verbatim: true, start: start)
            guard peek() == ">" else { throw error("expected '>' to close verbatim tag") }
            forward()
            spec = .verbatim(uri)
        } else if isBlankOrBreakOrEnd(1) || (flowLevel > 0 && flowIndicators.contains(peek(1))) {
            forward()
            spec = .nonSpecific
        } else {
            var length = 1
            var hasHandle = false
            while !isBlankOrBreakOrEnd(length) && !flowIndicators.contains(peek(length)) {
                if peek(length) == "!" { hasHandle = true; break }
                length += 1
            }
            let handle: String
            if hasHandle {
                handle = try scanTagHandle(start: start)
            } else {
                handle = "!"
                forward()
            }
            let suffix = try scanTagURI(verbatim: false, start: start)
            spec = .shorthand(handle: handle, suffix: suffix)
        }
        guard isBlankOrBreakOrEnd() || (flowLevel > 0 && flowIndicators.contains(peek())) else {
            throw error("expected whitespace after tag")
        }
        append(.tag(spec), start)
    }

    private mutating func fetchBlockScalar(folded: Bool) throws(YAMLError) {
        allowSimpleKey = true
        try removeSimpleKey()
        tokens.append(try scanBlockScalar(folded: folded))
    }

    private mutating func fetchFlowScalar(double: Bool) throws(YAMLError) {
        try saveSimpleKey()
        allowSimpleKey = false
        tokens.append(try scanFlowScalar(double: double))
        lastTokenJSONLike = true
        lastTokenKeyLike = true
    }

    private mutating func fetchPlain() throws(YAMLError) {
        try saveSimpleKey()
        allowSimpleKey = false
        tokens.append(try scanPlain())
        lastTokenKeyLike = true
    }

    // MARK: Directives and tags

    private mutating func scanDirective() throws(YAMLError) -> Token? {
        let start = mark
        forward()
        var length = 0
        while !isBlankOrBreakOrEnd(length) { length += 1 }
        let name = substring(length)
        guard !name.isEmpty else { throw error("expected directive name") }
        forward(length)
        var token: Token?
        switch name {
        case "YAML":
            skipBlanks()
            let major = try scanVersionNumber()
            guard peek() == "." else { throw error("expected '.' in %YAML version") }
            forward()
            let minor = try scanVersionNumber()
            token = Token(kind: .versionDirective(major: major, minor: minor), start: start)
        case "TAG":
            skipBlanks()
            let handle = try scanTagHandle(start: start)
            guard Self.isBlank(peek()) else { throw error("expected whitespace after %TAG handle") }
            skipBlanks()
            let prefix = try scanTagURI(verbatim: true, start: start)
            token = Token(kind: .tagDirective(handle: handle, prefix: prefix), start: start)
        default:
            // Reserved directives are ignored, as the specification requires.
            while !isBreakOrEnd() { forward() }
        }
        skipBlanks()
        if peek() == "#" && !atEnd {
            if index > 0 && !Self.isBlank(s[index - 1]) { throw error("comments must be separated from other tokens by whitespace") }
            while !isBreakOrEnd() { forward() }
        }
        guard isBreakOrEnd() else { throw error("expected comment or line break after directive") }
        return token
    }

    private mutating func skipBlanks() {
        while Self.isBlank(peek()) && !atEnd { forward() }
    }

    private mutating func scanVersionNumber() throws(YAMLError) -> Int {
        var value = 0
        var digits = 0
        while ("0"..."9").contains(peek()) && !atEnd {
            value = value * 10 + Int(peek().value - 48)
            digits += 1
            forward()
            guard digits <= 4 else { throw error("%YAML version number is too long") }
        }
        guard digits > 0 else { throw error("expected a digit in %YAML version") }
        return value
    }

    private mutating func scanTagHandle(start: Mark) throws(YAMLError) -> String {
        guard peek() == "!" else { throw error("expected '!' to start tag handle") }
        var handle = "!"
        forward()
        while peek().isASCII && (peek().properties.isAlphabetic || ("0"..."9").contains(peek()) || peek() == "-") {
            handle.unicodeScalars.append(peek())
            forward()
        }
        if peek() == "!" {
            handle += "!"
            forward()
        } else if handle != "!" {
            throw error("expected '!' to end tag handle")
        }
        return handle
    }

    private mutating func scanTagURI(verbatim: Bool, start: Mark) throws(YAMLError) -> String {
        var bytes: [UInt8] = []
        let uriPunctuation = "-;/?:@&=+$,_.!~*'()[]#".unicodeScalars
        while true {
            let c = peek()
            if atEnd { break }
            if c == "%" {
                guard let hi = hexValue(peek(1)), let lo = hexValue(peek(2)) else {
                    throw error("invalid %-escape in tag")
                }
                bytes.append(UInt8(hi * 16 + lo))
                forward(3)
                continue
            }
            let isWord = c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c))
            guard isWord || uriPunctuation.contains(c) else { break }
            if !verbatim && (c == "!" || flowIndicators.contains(c)) { break }
            bytes.append(contentsOf: Array(String(c).utf8))
            forward()
        }
        guard !bytes.isEmpty else { throw error("tag must not be empty", start) }
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw error("tag %-escapes are not valid UTF-8", start)
        }
        return text
    }

    // MARK: Block scalars

    private mutating func scanBlockScalar(folded: Bool) throws(YAMLError) -> Token {
        let start = mark
        forward()
        var chomping: Bool?  // nil = clip, true = keep, false = strip
        var increment: Int?
        func digit(_ c: Unicode.Scalar) -> Int? { ("0"..."9").contains(c) ? Int(c.value - 48) : nil }
        if peek() == "+" || peek() == "-" {
            chomping = peek() == "+"
            forward()
            if let d = digit(peek()) {
                guard d > 0 else { throw error("indentation indicator must be 1 to 9") }
                increment = d
                forward()
            }
        } else if let d = digit(peek()) {
            guard d > 0 else { throw error("indentation indicator must be 1 to 9") }
            increment = d
            forward()
            if peek() == "+" || peek() == "-" {
                chomping = peek() == "+"
                forward()
            }
        }
        skipBlanks()
        if peek() == "#" && !atEnd {
            guard index > 0 && Self.isBlank(s[index - 1]) else {
                throw error("comments must be separated from other tokens by whitespace")
            }
            while !isBreakOrEnd() { forward() }
        }
        guard isBreakOrEnd() else { throw error("expected comment or line break after block scalar header") }
        if scanLineBreak().isEmpty {  // header at end of input: no content lines at all
            return Token(kind: .scalar("", folded ? .folded : .literal), start: start)
        }

        let minIndent = indent + 1
        var chunks = ""
        var breaks: String
        var blockIndent: Int
        if let increment {
            blockIndent = indent >= 0 ? indent + increment : increment
            breaks = try scanBlockScalarBreaks(blockIndent)
        } else {
            var maxIndent = 0
            var maxBlankIndent = 0
            breaks = ""
            while (peek() == " " || Self.isBreak(peek())) && !atEnd {
                if peek() == " " {
                    forward()
                    maxIndent = max(maxIndent, column)
                } else {
                    maxBlankIndent = max(maxBlankIndent, column)
                    breaks += scanLineBreak()
                }
            }
            if atEnd && column > 0 { breaks += "\n" }  // a final blank line without a line break
            if peek() == "\t" && column < minIndent && !atEnd {
                throw error("tab characters must not be used for indentation")
            }
            blockIndent = max(minIndent, maxIndent)
            if !isBreakOrEnd() && maxBlankIndent > column && column >= minIndent {
                throw error("a leading empty line has more spaces than the first content line")
            }
            if blockIndent > column {
                // Rewind is unnecessary: the content line is less indented, so the scalar is empty.
            }
        }
        var lineBreak = ""
        while column == blockIndent && !atEnd && !atDocumentMarker() {
            chunks += breaks
            let leadingNonSpace = !Self.isBlank(peek())
            var length = 0
            while !isBreakOrEnd(length) { length += 1 }
            chunks += substring(length)
            forward(length)
            lineBreak = scanLineBreak()
            if lineBreak.isEmpty { lineBreak = "\n" }  // the last line ends at end of input
            breaks = try scanBlockScalarBreaks(blockIndent)
            if column == blockIndent && !atEnd && !atDocumentMarker() {
                if folded && lineBreak == "\n" && leadingNonSpace && !Self.isBlank(peek()) {
                    if breaks.isEmpty { chunks += " " }
                } else {
                    chunks += lineBreak
                }
            } else {
                break
            }
        }
        if chomping != false { chunks += lineBreak }
        if chomping == true { chunks += breaks }
        return Token(kind: .scalar(chunks, folded ? .folded : .literal), start: start)
    }

    private mutating func scanBlockScalarBreaks(_ blockIndent: Int) throws(YAMLError) -> String {
        var chunks = ""
        while column < blockIndent && peek() == " " { forward() }
        while Self.isBreak(peek()) && !atEnd {
            chunks += scanLineBreak()
            while column < blockIndent && peek() == " " { forward() }
        }
        if atEnd && column > 0 { chunks += "\n" }
        if peek() == "\t" && column < blockIndent && !atEnd {
            var j = index
            while j < s.count && Self.isBlank(s[j]) { j += 1 }
            if j >= s.count || Self.isBreak(s[j]) {
                throw error("tab characters must not be used for indentation")
            }
        }
        return chunks
    }

    // MARK: Flow scalars

    private mutating func scanFlowScalar(double: Bool) throws(YAMLError) -> Token {
        let start = mark
        let quote = peek()
        forward()
        var chunks = try scanFlowScalarNonSpaces(double: double, start: start)
        while peek() != quote || atEnd {
            chunks += try scanFlowScalarSpaces(start: start)
            chunks += try scanFlowScalarNonSpaces(double: double, start: start)
        }
        forward()
        return Token(kind: .scalar(chunks, double ? .doubleQuoted : .singleQuoted), start: start)
    }

    private mutating func scanFlowScalarNonSpaces(double: Bool, start: Mark) throws(YAMLError) -> String {
        var chunks = ""
        while true {
            var length = 0
            while true {
                let c = peek(length)
                if index + length >= s.count || c == "'" || c == "\"" || c == "\\" || Self.isBlank(c) || Self.isBreak(c) { break }
                length += 1
            }
            if length > 0 {
                chunks += substring(length)
                forward(length)
            }
            let c = peek()
            if atEnd { return chunks }
            if !double && c == "'" && peek(1) == "'" {
                chunks += "'"
                forward(2)
            } else if (double && c == "'") || (!double && (c == "\"" || c == "\\")) {
                chunks.unicodeScalars.append(c)
                forward()
            } else if double && c == "\\" {
                let escapeMark = mark
                forward()
                let e = peek()
                if let mapped = Self.escapes[e] {
                    chunks.unicodeScalars.append(mapped)
                    forward()
                } else if e == "x" || e == "u" || e == "U" {
                    let count = e == "x" ? 2 : (e == "u" ? 4 : 8)
                    forward()
                    var value: UInt32 = 0
                    for k in 0..<count {
                        guard let h = hexValue(peek(k)) else {
                            throw error("expected \(count) hexadecimal digits in escape", escapeMark)
                        }
                        value = value * 16 + UInt32(h)
                    }
                    guard let scalar = Unicode.Scalar(value) else {
                        throw error("escape \\\(e) does not name a Unicode scalar value", escapeMark)
                    }
                    chunks.unicodeScalars.append(scalar)
                    forward(count)
                } else if Self.isBreak(e) {
                    _ = scanLineBreak()
                    chunks += try scanFlowScalarBreaks(start: start)
                    // An escaped line break also drops leading blanks of the next line.
                } else {
                    throw error("unknown escape character '\(e.escaped(asASCII: true))'", escapeMark)
                }
            } else {
                return chunks
            }
        }
    }

    private static let escapes: [Unicode.Scalar: Unicode.Scalar] = [
        "0": "\0", "a": "\u{07}", "b": "\u{08}", "t": "\t", "\t": "\t", "n": "\n", "v": "\u{0B}",
        "f": "\u{0C}", "r": "\r", "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\",
        "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
    ]

    private mutating func scanFlowScalarSpaces(start: Mark) throws(YAMLError) -> String {
        var length = 0
        while Self.isBlank(peek(length)) && index + length < s.count { length += 1 }
        let whitespace = substring(length)
        forward(length)
        if atEnd { throw error("found unexpected end of stream in quoted scalar", start) }
        if Self.isBreak(peek()) {
            _ = scanLineBreak()
            let breaks = try scanFlowScalarBreaks(start: start)
            return breaks.isEmpty ? " " : breaks
        }
        return whitespace
    }

    private mutating func scanFlowScalarBreaks(start: Mark) throws(YAMLError) -> String {
        var chunks = ""
        while true {
            if atDocumentMarker() { throw error("found document marker inside quoted scalar") }
            while peek() == " " && !atEnd { forward() }
            let spaces = column
            while Self.isBlank(peek()) && !atEnd { forward() }
            if Self.isBreak(peek()) && !atEnd {
                chunks += scanLineBreak()
            } else {
                if flowLevel == 0 && spaces <= indent && !atEnd {
                    throw error("continuation line of quoted scalar is not indented enough")
                }
                return chunks
            }
        }
    }

    // MARK: Plain scalars

    private mutating func scanPlain() throws(YAMLError) -> Token {
        let start = mark
        let indentLimit = indent + 1
        var chunks = ""
        var spaces = ""
        while true {
            if peek() == "#" { break }
            var length = 0
            while true {
                if isBlankOrBreakOrEnd(length) { break }
                let c = peek(length)
                if c == ":" && (isBlankOrBreakOrEnd(length + 1) || (flowLevel > 0 && flowIndicators.contains(peek(length + 1)))) { break }
                if flowLevel > 0 && flowIndicators.contains(c) { break }
                length += 1
            }
            if length == 0 { break }
            allowSimpleKey = false
            chunks += spaces
            chunks += substring(length)
            forward(length)
            guard let next = try scanPlainSpaces(indentLimit: indentLimit) else { break }
            spaces = next
            if peek() == "#" || (flowLevel == 0 && column < indentLimit) { break }
        }
        return Token(kind: .scalar(chunks, .plain), start: start)
    }

    /// Returns the folded separator, or nil when the scalar must end here.
    private mutating func scanPlainSpaces(indentLimit: Int) throws(YAMLError) -> String? {
        var length = 0
        while Self.isBlank(peek(length)) && index + length < s.count { length += 1 }
        let whitespace = substring(length)
        forward(length)
        if atEnd { return nil }
        guard Self.isBreak(peek()) else { return whitespace.isEmpty ? nil : whitespace }
        _ = scanLineBreak()
        allowSimpleKey = true
        if atDocumentMarker() { return nil }
        var breaks = ""
        while !atEnd && (Self.isBlank(peek()) || Self.isBreak(peek())) {
            if Self.isBlank(peek()) {
                forward()
            } else {
                breaks += scanLineBreak()
                if atDocumentMarker() { return nil }
            }
        }
        return breaks.isEmpty ? " " : breaks
    }
}

private func hexValue(_ c: Unicode.Scalar) -> Int? {
    switch c {
    case "0"..."9": Int(c.value - 48)
    case "a"..."f": Int(c.value - 87)
    case "A"..."F": Int(c.value - 55)
    default: nil
    }
}
