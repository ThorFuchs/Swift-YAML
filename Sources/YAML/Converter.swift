// SPDX-License-Identifier: Apache-2.0
// Representation graph to exact JSON under the YAML 1.2 core schema.
import JSON

private let yamlTagPrefix = "tag:yaml.org,2002:"

struct Converter {
    private struct Converted {
        var json: JSON
        /// Nodes in the expanded value, including mapping keys.
        var size: Int
        /// Nesting levels of collections; a scalar has height 0.
        var height: Int
    }

    private let limits: YAMLLimits
    private let jsonLimits: JSONLimits
    private var anchored: [Int: Converted] = [:]
    private var totalNodes = 0
    private var aliasNodes = 0

    init(limits: YAMLLimits) {
        self.limits = limits
        var jsonLimits = JSONLimits(profile: .offline)
        jsonLimits[.maxDepth] = max(jsonLimits[.maxDepth], UInt64(max(0, limits.maxDepth)) + 2)
        jsonLimits[.nodes] = max(jsonLimits[.nodes], UInt64(max(0, limits.maxNodes)) + 1)
        jsonLimits[.objectMembers] = max(jsonLimits[.objectMembers], UInt64(max(0, limits.maxNodes)))
        jsonLimits[.arrayItems] = max(jsonLimits[.arrayItems], UInt64(max(0, limits.maxNodes)))
        self.jsonLimits = jsonLimits
    }

    mutating func convert(_ node: Node) throws(YAMLError) -> JSON {
        try convert(node, depth: 0).json
    }

    private mutating func countNodes(_ n: Int, at mark: Mark) throws(YAMLError) {
        totalNodes += n
        if totalNodes > limits.maxNodes {
            throw YAMLError(.nodeLimitExceeded, "more than \(limits.maxNodes) nodes", at: mark)
        }
        if totalNodes & 1023 == 0 && Task.isCancelled {
            throw YAMLError(.cancelled, "parsing was cancelled", at: mark)
        }
    }

    private mutating func convert(_ node: Node, depth: Int) throws(YAMLError) -> Converted {
        var result: Converted
        switch node.kind {
        case .alias(let id, let name):
            guard let target = anchored[id] else {
                throw YAMLError(.undefinedAlias, "alias *\(name) has no preceding anchor", at: node.mark)
            }
            aliasNodes += target.size
            if aliasNodes > limits.maxAliasExpansion {
                throw YAMLError(.aliasExpansionLimitExceeded,
                                "alias expansion exceeds \(limits.maxAliasExpansion) nodes", at: node.mark)
            }
            if depth + target.height > limits.maxDepth {
                throw YAMLError(.depthLimitExceeded, "nesting is deeper than \(limits.maxDepth)", at: node.mark)
            }
            try countNodes(target.size, at: node.mark)
            return target

        case .scalar(let text, let style):
            result = Converted(json: try resolveScalar(text, style: style, tag: node.tag, mark: node.mark), size: 1, height: 0)

        case .sequence(let items):
            try checkCollectionTag(node, expected: "seq")
            guard depth < limits.maxDepth else {
                throw YAMLError(.depthLimitExceeded, "nesting is deeper than \(limits.maxDepth)", at: node.mark)
            }
            var values: [JSON] = []
            values.reserveCapacity(items.count)
            var size = 1, height = 1
            for item in items {
                let converted = try convert(item, depth: depth + 1)
                values.append(converted.json)
                size += converted.size
                height = max(height, converted.height + 1)
            }
            result = Converted(json: .array(values), size: size, height: height)

        case .mapping(let pairs):
            try checkCollectionTag(node, expected: "map")
            guard depth < limits.maxDepth else {
                throw YAMLError(.depthLimitExceeded, "nesting is deeper than \(limits.maxDepth)", at: node.mark)
            }
            var members: [JSONMember] = []
            members.reserveCapacity(pairs.count)
            var seen = Set<JSONKey>()
            var size = 1, height = 1
            for pair in pairs {
                let key = try convert(pair.key, depth: depth + 1)
                guard case .string(let keyText) = key.json else {
                    throw YAMLError(.nonStringKey, "mapping key must be a string, found \(Self.kindName(key.json))",
                                    at: pair.key.mark)
                }
                let jsonKey = JSONKey(keyText)
                guard seen.insert(jsonKey).inserted else {
                    throw YAMLError(.duplicateKey, "duplicate mapping key \"\(keyText)\"", at: pair.key.mark)
                }
                let value = try convert(pair.value, depth: depth + 1)
                members.append(JSONMember(jsonKey, value: value.json))
                size += key.size + value.size
                height = max(height, value.height + 1)
            }
            let object: JSONObject
            do {
                object = try JSONObject(members: members, limits: jsonLimits)
            } catch {
                throw YAMLError(.nodeLimitExceeded, "mapping exceeds Swift-JSON construction limits", at: node.mark)
            }
            result = Converted(json: .object(object), size: size, height: height)
        }
        try countNodes(1, at: node.mark)
        if let id = node.anchorID { anchored[id] = result }
        return result
    }

    private static func kindName(_ json: JSON) -> String {
        switch json {
        case .null: "null"
        case .boolean: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "a sequence"
        case .object: "a mapping"
        }
    }

    private func checkCollectionTag(_ node: Node, expected: String) throws(YAMLError) {
        guard let tag = node.tag, tag != "!", tag != yamlTagPrefix + expected else { return }
        if tag.hasPrefix(yamlTagPrefix), ["str", "int", "float", "bool", "null", "seq", "map"].contains(tag.dropFirst(yamlTagPrefix.count)) {
            throw YAMLError(.invalidTaggedValue, "tag \(Self.display(tag)) cannot be applied to a \(expected == "seq" ? "sequence" : "mapping")",
                            at: node.mark)
        }
        throw YAMLError(.unsupportedTag, "unsupported tag \(Self.display(tag))", at: node.mark)
    }

    static func display(_ tag: String) -> String {
        tag.hasPrefix(yamlTagPrefix) ? "!!" + tag.dropFirst(yamlTagPrefix.count) : tag
    }

    // MARK: Scalars

    private func resolveScalar(_ text: String, style: ScalarStyle, tag: String?, mark: Mark) throws(YAMLError) -> JSON {
        guard let tag else {
            return style == .plain ? try resolvePlain(text, mark: mark) : .string(text)
        }
        if tag == "!" { return .string(text) }
        guard tag.hasPrefix(yamlTagPrefix) else {
            throw YAMLError(.unsupportedTag, "unsupported tag \(tag)", at: mark)
        }
        func invalid() -> YAMLError {
            YAMLError(.invalidTaggedValue, "\"\(text)\" is not a valid \(Self.display(tag)) value", at: mark)
        }
        switch tag.dropFirst(yamlTagPrefix.count) {
        case "str":
            return .string(text)
        case "null":
            guard CoreSchema.isNull(text) else { throw invalid() }
            return .null
        case "bool":
            guard let value = CoreSchema.bool(text) else { throw invalid() }
            return .boolean(value)
        case "int":
            guard let decimal = CoreSchema.integerDecimalText(text) else { throw invalid() }
            return try number(decimal, mark: mark)
        case "float":
            if CoreSchema.isNonFinite(text) { throw nonFinite(text, mark) }
            guard let decimal = CoreSchema.floatDecimalText(text) else { throw invalid() }
            return try number(decimal, mark: mark)
        case "seq", "map":
            throw YAMLError(.invalidTaggedValue, "tag \(Self.display(tag)) cannot be applied to a scalar", at: mark)
        default:
            throw YAMLError(.unsupportedTag, "unsupported tag \(Self.display(tag))", at: mark)
        }
    }

    private func resolvePlain(_ text: String, mark: Mark) throws(YAMLError) -> JSON {
        if CoreSchema.isNull(text) { return .null }
        if let value = CoreSchema.bool(text) { return .boolean(value) }
        if let decimal = CoreSchema.integerDecimalText(text) ?? CoreSchema.floatDecimalText(text) {
            return try number(decimal, mark: mark)
        }
        if CoreSchema.isNonFinite(text) { throw nonFinite(text, mark) }
        return .string(text)
    }

    private func nonFinite(_ text: String, _ mark: Mark) -> YAMLError {
        YAMLError(.nonFiniteNumber, "\(text) is not a finite number and cannot be represented in JSON", at: mark)
    }

    private func number(_ decimal: String, mark: Mark) throws(YAMLError) -> JSON {
        do {
            return .number(try JSONNumber(parsing: decimal, limits: .balanced))
        } catch {
            throw YAMLError(.numberOutOfRange, "number exceeds Swift-JSON's exact-number limits", at: mark)
        }
    }
}

/// YAML 1.2.2 core schema (section 10.3.2) tag resolution.
enum CoreSchema {
    static func isNull(_ text: String) -> Bool {
        text.isEmpty || text == "~" || text == "null" || text == "Null" || text == "NULL"
    }

    static func bool(_ text: String) -> Bool? {
        switch text {
        case "true", "True", "TRUE": true
        case "false", "False", "FALSE": false
        default: nil
        }
    }

    static func isNonFinite(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        if body == ".inf" || body == ".Inf" || body == ".INF" { return true }
        return text == ".nan" || text == ".NaN" || text == ".NAN"
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }

    /// Maximum source digits for hexadecimal/octal conversion (keeps base conversion cheap).
    static let maxRadixDigits = 3000
    /// Returned for over-long hexadecimal/octal literals; it is not a JSON number, so conversion reports `numberOutOfRange`.
    static let tooManyDigits = "too-many-digits"

    /// JSON decimal text for `[-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+`, or nil.
    static func integerDecimalText(_ text: String) -> String? {
        let b = Array(text.utf8)
        guard !b.isEmpty else { return nil }
        if b.count > 2 && b[0] == 48 && (b[1] == 111 || b[1] == 120) {  // 0o / 0x
            let radix = b[1] == 111 ? 8 : 16
            var values: [Int] = []
            for byte in b[2...] {
                let v: Int
                switch byte {
                case 48...57: v = Int(byte) - 48
                case 97...102: v = Int(byte) - 87
                case 65...70: v = Int(byte) - 55
                default: return nil
                }
                guard v < radix else { return nil }
                values.append(v)
            }
            guard values.count <= maxRadixDigits else { return tooManyDigits }
            return decimalString(values, radix: radix)
        }
        var i = 0
        var negative = false
        if b[0] == 43 || b[0] == 45 { negative = b[0] == 45; i = 1 }
        guard i < b.count, b[i...].allSatisfy(isDigit) else { return nil }
        var digits = b[i...].drop { $0 == 48 }
        if digits.isEmpty { digits = [48][...] }
        return (negative ? "-" : "") + String(decoding: digits, as: UTF8.self)
    }

    /// JSON decimal text for `[-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?`, or nil.
    static func floatDecimalText(_ text: String) -> String? {
        let b = Array(text.utf8)
        var i = 0
        var negative = false
        if i < b.count && (b[i] == 43 || b[i] == 45) { negative = b[i] == 45; i += 1 }
        let intStart = i
        while i < b.count && isDigit(b[i]) { i += 1 }
        var integerPart = Array(b[intStart..<i])
        var fraction: [UInt8] = []
        if i < b.count && b[i] == 46 {
            i += 1
            let fracStart = i
            while i < b.count && isDigit(b[i]) { i += 1 }
            fraction = Array(b[fracStart..<i])
            if integerPart.isEmpty && fraction.isEmpty { return nil }
        } else if integerPart.isEmpty {
            return nil
        }
        var exponent = ""
        if i < b.count && (b[i] == 101 || b[i] == 69) {
            i += 1
            var sign = ""
            if i < b.count && (b[i] == 43 || b[i] == 45) { sign = b[i] == 45 ? "-" : ""; i += 1 }
            let expStart = i
            while i < b.count && isDigit(b[i]) { i += 1 }
            guard i > expStart else { return nil }
            exponent = "e" + sign + String(decoding: b[expStart..<i], as: UTF8.self)
        }
        guard i == b.count else { return nil }
        while integerPart.count > 1 && integerPart[0] == 48 { integerPart.removeFirst() }
        if integerPart.isEmpty { integerPart = [48] }
        var result = (negative ? "-" : "") + String(decoding: integerPart, as: UTF8.self)
        if !fraction.isEmpty { result += "." + String(decoding: fraction, as: UTF8.self) }
        return result + exponent
    }

    private static func decimalString(_ values: [Int], radix: Int) -> String {
        var decimal: [Int] = [0]  // little-endian base-10 digits
        for value in values {
            var carry = value
            for k in decimal.indices {
                let product = decimal[k] * radix + carry
                decimal[k] = product % 10
                carry = product / 10
            }
            while carry > 0 { decimal.append(carry % 10); carry /= 10 }
        }
        while decimal.count > 1 && decimal.last == 0 { decimal.removeLast() }
        return String(decimal.reversed().map { Character(Unicode.Scalar(UInt8(48 + $0))) })
    }
}
