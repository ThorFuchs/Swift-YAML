// SPDX-License-Identifier: Apache-2.0
// Recursive-descent parser from tokens to a representation graph (nodes plus aliases).

struct Node: Sendable {
    indirect enum Kind: Sendable {
        case scalar(String, ScalarStyle)
        case sequence([Node])
        case mapping([(key: Node, value: Node)])
        /// Refers to the anchored node with this id.
        case alias(Int, name: String)
    }

    var kind: Kind
    /// The fully resolved tag (`tag:yaml.org,2002:str`, `!`, `!local`), or nil when untagged.
    var tag: String?
    var mark: Mark
    /// Set when the node carries an anchor; aliases refer to it by this id.
    var anchorID: Int?

    static func empty(at mark: Mark, tag: String? = nil) -> Node {
        Node(kind: .scalar("", .plain), tag: tag, mark: mark)
    }
}

struct Parser {
    private var scanner: Scanner
    private let limits: YAMLLimits
    private var tagHandles: [String: String] = [:]
    private var anchors: [String: Int] = [:]
    private var openAnchors: Set<String> = []
    private var nextAnchorID = 0
    private(set) var nodeCount = 0

    init(_ scalars: [Unicode.Scalar], limits: YAMLLimits) {
        scanner = Scanner(scalars)
        self.limits = limits
    }

    private static let defaultHandles = ["!": "!", "!!": "tag:yaml.org,2002:"]

    private func error(_ message: String, _ token: Token) -> YAMLError {
        YAMLError(.syntax, message, at: token.start)
    }

    private mutating func peek() throws(YAMLError) -> Token { try scanner.peekToken() }

    @discardableResult
    private mutating func next() throws(YAMLError) -> Token { try scanner.nextToken() }

    private mutating func check(_ predicate: (TokenKind) -> Bool) throws(YAMLError) -> Bool {
        predicate(try peek().kind)
    }

    /// Parses the whole stream into document root nodes.
    mutating func parseStream() throws(YAMLError) -> [Node] {
        _ = try next()  // stream start
        var documents: [Node] = []
        while true {
            while case .documentEnd = try peek().kind { try next() }
            if case .streamEnd = try peek().kind { break }
            tagHandles = Self.defaultHandles
            anchors = [:]
            var sawDirective = false
            var sawVersion = false
            while true {
                let token = try peek()
                if case .versionDirective(let major, _) = token.kind {
                    guard !sawVersion else { throw error("duplicate %YAML directive", token) }
                    guard major == 1 else { throw error("unsupported YAML version \(major).x", token) }
                    sawVersion = true
                } else if case .tagDirective(let handle, let prefix) = token.kind {
                    guard !declaredHandles.contains(handle) else {
                        throw error("duplicate %TAG directive for \(handle)", token)
                    }
                    tagHandles[handle] = prefix
                    declaredHandles.insert(handle)
                } else {
                    break
                }
                sawDirective = true
                try next()
            }
            declaredHandles = []
            let root: Node
            let start = try peek()
            if case .documentStart = start.kind {
                try next()
                let content = try peek()
                switch content.kind {
                case .versionDirective, .tagDirective, .documentStart, .documentEnd, .streamEnd:
                    root = try countNode(.empty(at: content.start))
                default:
                    root = try parseNode(block: true, indentlessSequence: false)
                }
            } else {
                if sawDirective { throw error("expected '---' after directives", start) }
                root = try parseNode(block: true, indentlessSequence: false)
            }
            documents.append(root)
            let after = try peek()
            switch after.kind {
            case .documentEnd, .documentStart, .streamEnd: break
            default: throw error("expected end of document, but found \(after.kind.name)", after)
            }
        }
        return documents
    }

    private var declaredHandles: Set<String> = []

    private mutating func countNode(_ node: Node) throws(YAMLError) -> Node {
        nodeCount += 1
        if nodeCount > limits.maxNodes {
            throw YAMLError(.nodeLimitExceeded, "more than \(limits.maxNodes) nodes", at: node.mark)
        }
        if nodeCount & 1023 == 0 && Task.isCancelled {
            throw YAMLError(.cancelled, "parsing was cancelled", at: node.mark)
        }
        return node
    }

    private mutating func resolveTag(_ spec: TagSpec, _ token: Token) throws(YAMLError) -> String {
        switch spec {
        case .verbatim(let uri): return uri
        case .nonSpecific: return "!"
        case .shorthand(let handle, let suffix):
            guard let prefix = tagHandles[handle] else {
                throw error("undefined tag handle \(handle)", token)
            }
            return prefix + suffix
        }
    }

    // MARK: Nodes (explicit stack, so nesting depth never grows the call stack)

    private struct Properties {
        var anchor: String?
        var tag: String?
        var mark: Mark
    }

    private struct Frame {
        enum Kind { case blockSequence, indentlessSequence, blockMapping, flowSequence, flowPair, flowMapping }
        var kind: Kind
        var properties: Properties?
        var mark: Mark
        var items: [Node] = []
        var pairs: [(key: Node, value: Node)] = []
        var pendingKey: Node?
        var first = true

        var isMapping: Bool { kind == .blockMapping || kind == .flowPair || kind == .flowMapping }
    }

    /// What the loop does next.
    private enum Step {
        /// Parse a node at the current token.
        case node(block: Bool, indentless: Bool)
        /// Hand a finished node to the innermost open collection.
        case deliver(Node)
        /// Let the innermost collection read its next entry.
        case resume
    }

    private static func isBlockStop(_ kind: TokenKind) -> Bool { kind == .key || kind == .value || kind == .blockEnd }

    /// Parses one complete node (the document root).
    private mutating func parseNode(block: Bool, indentlessSequence: Bool) throws(YAMLError) -> Node {
        var stack: [Frame] = []
        var step = Step.node(block: block, indentless: indentlessSequence)
        while true {
            switch step {
            case .node(let block, let indentless):
                step = try startNode(block: block, indentless: indentless, stack: &stack)
            case .deliver(let node):
                guard !stack.isEmpty else { return node }
                step = try deliver(node, stack: &stack)
            case .resume:
                step = try resume(stack: &stack)
            }
        }
    }

    private mutating func empty(at mark: Mark) throws(YAMLError) -> Node {
        try countNode(.empty(at: mark))
    }

    /// Parses a node or the empty node if the next token is in `stop`.
    private mutating func nodeOrEmpty(block: Bool, indentless: Bool, stop: (TokenKind) -> Bool) throws(YAMLError) -> Step {
        let token = try peek()
        if stop(token.kind) { return .deliver(try empty(at: token.start)) }
        return .node(block: block, indentless: indentless)
    }

    private mutating func push(_ kind: Frame.Kind, properties: Properties?, mark: Mark, stack: inout [Frame]) throws(YAMLError) {
        if stack.count + 1 > limits.maxDepth {
            throw YAMLError(.depthLimitExceeded, "nesting is deeper than \(limits.maxDepth)", at: mark)
        }
        stack.append(Frame(kind: kind, properties: properties, mark: mark))
    }

    private mutating func finish(_ node: Node, properties: Properties?) throws(YAMLError) -> Node {
        var node = node
        if let properties {
            node.tag = properties.tag
            node.mark = properties.mark
            if let anchor = properties.anchor {
                openAnchors.remove(anchor)
                node.anchorID = nextAnchorID
                anchors[anchor] = nextAnchorID
                nextAnchorID += 1
            }
        }
        return try countNode(node)
    }

    private mutating func startNode(block: Bool, indentless: Bool, stack: inout [Frame]) throws(YAMLError) -> Step {
        let first = try peek()
        if case .alias(let name) = first.kind {
            try next()
            guard let id = anchors[name] else {
                if openAnchors.contains(name) {
                    throw YAMLError(.undefinedAlias, "alias *\(name) refers to the node that contains it", at: first.start)
                }
                throw YAMLError(.undefinedAlias, "alias *\(name) has no preceding anchor", at: first.start)
            }
            return .deliver(try countNode(Node(kind: .alias(id, name: name), mark: first.start)))
        }
        var properties: Properties?
        for _ in 0..<2 {
            let token = try peek()
            if case .anchor(let name) = token.kind, properties?.anchor == nil {
                try next()
                properties = properties ?? Properties(mark: first.start)
                properties?.anchor = name
            } else if case .tag(let spec) = token.kind, properties?.tag == nil {
                try next()
                let tag = try resolveTag(spec, token)
                properties = properties ?? Properties(mark: first.start)
                properties?.tag = tag
            } else {
                break
            }
        }
        if let anchor = properties?.anchor {
            openAnchors.insert(anchor)
            anchors[anchor] = nil
        }
        let token = try peek()
        switch token.kind {
        case .blockEntry where indentless:
            try push(.indentlessSequence, properties: properties, mark: token.start, stack: &stack)
            return .resume
        case .scalar(let text, let style):
            try next()
            return .deliver(try finish(Node(kind: .scalar(text, style), mark: token.start), properties: properties))
        case .flowSequenceStart:
            try next()
            try push(.flowSequence, properties: properties, mark: token.start, stack: &stack)
            return .resume
        case .flowMappingStart:
            try next()
            try push(.flowMapping, properties: properties, mark: token.start, stack: &stack)
            return .resume
        case .blockSequenceStart where block:
            try next()
            try push(.blockSequence, properties: properties, mark: token.start, stack: &stack)
            return .resume
        case .blockMappingStart where block:
            try next()
            try push(.blockMapping, properties: properties, mark: token.start, stack: &stack)
            return .resume
        default:
            guard let properties else {
                throw error("expected a node, but found \(token.kind.name)", token)
            }
            return .deliver(try finish(.empty(at: properties.mark), properties: properties))
        }
    }

    /// Closes the innermost collection and returns it as a finished node.
    private mutating func close(stack: inout [Frame]) throws(YAMLError) -> Step {
        guard let frame = stack.popLast() else { throw YAMLError(.syntax, "internal parser state error", at: .start) }
        let kind: Node.Kind = frame.isMapping ? .mapping(frame.pairs) : .sequence(frame.items)
        return .deliver(try finish(Node(kind: kind, mark: frame.mark), properties: frame.properties))
    }

    /// After a mapping key: reads `: value` or supplies an empty value.
    private mutating func valueStep(block: Bool, closing: TokenKind?) throws(YAMLError) -> Step {
        let token = try peek()
        guard case .value = token.kind else { return .deliver(try empty(at: token.start)) }
        try next()
        if block {
            return try nodeOrEmpty(block: true, indentless: true, stop: Self.isBlockStop)
        }
        return try nodeOrEmpty(block: false, indentless: false) { $0 == .flowEntry || $0 == closing }
    }

    private mutating func deliver(_ node: Node, stack: inout [Frame]) throws(YAMLError) -> Step {
        let top = stack.count - 1
        if !stack[top].isMapping {
            stack[top].items.append(node)
            return .resume
        }
        guard let key = stack[top].pendingKey else {
            stack[top].pendingKey = node
            switch stack[top].kind {
            case .blockMapping: return try valueStep(block: true, closing: nil)
            case .flowPair: return try valueStep(block: false, closing: .flowSequenceEnd)
            default: return try valueStep(block: false, closing: .flowMappingEnd)
            }
        }
        stack[top].pendingKey = nil
        stack[top].pairs.append((key, node))
        if stack[top].kind == .flowPair { return try close(stack: &stack) }
        return .resume
    }

    private mutating func resume(stack: inout [Frame]) throws(YAMLError) -> Step {
        let top = stack.count - 1
        var token = try peek()
        switch stack[top].kind {
        case .blockSequence:
            switch token.kind {
            case .blockEntry:
                try next()
                return try nodeOrEmpty(block: true, indentless: false) { $0 == .blockEntry || $0 == .blockEnd }
            case .blockEnd:
                try next()
                return try close(stack: &stack)
            default:
                throw error("expected '-' or end of block sequence, but found \(token.kind.name)", token)
            }

        case .indentlessSequence:
            guard case .blockEntry = token.kind else { return try close(stack: &stack) }
            try next()
            return try nodeOrEmpty(block: true, indentless: false) { [.blockEntry, .key, .value, .blockEnd].contains($0) }

        case .blockMapping:
            switch token.kind {
            case .key:
                try next()
                return try nodeOrEmpty(block: true, indentless: true, stop: Self.isBlockStop)
            case .value:
                stack[top].pendingKey = try empty(at: token.start)
                return try valueStep(block: true, closing: nil)
            case .blockEnd:
                try next()
                return try close(stack: &stack)
            default:
                throw error("expected a mapping key or end of block mapping, but found \(token.kind.name)", token)
            }

        case .flowPair:
            // Only reached right after the pair was opened.
            return try flowEntryStart(token, closing: .flowSequenceEnd, stack: &stack)

        case .flowSequence, .flowMapping:
            let closing: TokenKind = stack[top].kind == .flowSequence ? .flowSequenceEnd : .flowMappingEnd
            if token.kind == closing { try next(); return try close(stack: &stack) }
            if !stack[top].first {
                guard case .flowEntry = token.kind else {
                    let expected = closing == .flowSequenceEnd ? "']'" : "'}'"
                    throw error("expected ',' or \(expected), but found \(token.kind.name)", token)
                }
                try next()
                token = try peek()
                if token.kind == closing { try next(); return try close(stack: &stack) }
            }
            stack[top].first = false
            if stack[top].kind == .flowSequence {
                switch token.kind {
                case .key, .value:
                    try push(.flowPair, properties: nil, mark: token.start, stack: &stack)
                    return try flowEntryStart(token, closing: closing, stack: &stack)
                default:
                    return .node(block: false, indentless: false)
                }
            }
            return try flowEntryStart(token, closing: closing, stack: &stack)
        }
    }

    /// Starts `? key : value`, `key: value`, `: value` or `key` inside a flow mapping or pair.
    private mutating func flowEntryStart(_ token: Token, closing: TokenKind, stack: inout [Frame]) throws(YAMLError) -> Step {
        switch token.kind {
        case .key:
            try next()
            return try nodeOrEmpty(block: false, indentless: false) { $0 == .value || $0 == .flowEntry || $0 == closing }
        case .value:
            stack[stack.count - 1].pendingKey = try empty(at: token.start)
            return try valueStep(block: false, closing: closing)
        default:
            return .node(block: false, indentless: false)
        }
    }
}
