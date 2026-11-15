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
                    root = try countNode(.empty(at: content.start), depth: 0)
                default:
                    root = try parseNode(block: true, indentlessSequence: false, depth: 0)
                }
            } else {
                if sawDirective { throw error("expected '---' after directives", start) }
                root = try parseNode(block: true, indentlessSequence: false, depth: 0)
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

    private mutating func countNode(_ node: Node, depth: Int) throws(YAMLError) -> Node {
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

    private mutating func parseNode(block: Bool, indentlessSequence: Bool, depth: Int) throws(YAMLError) -> Node {
        let first = try peek()
        if case .alias(let name) = first.kind {
            try next()
            guard let id = anchors[name] else {
                if openAnchors.contains(name) {
                    throw YAMLError(.undefinedAlias, "alias *\(name) refers to the node that contains it", at: first.start)
                }
                throw YAMLError(.undefinedAlias, "alias *\(name) has no preceding anchor", at: first.start)
            }
            return try countNode(Node(kind: .alias(id, name: name), mark: first.start), depth: depth)
        }
        var anchor: String?
        var tag: String?
        var start = first.start
        var sawProperty = false
        for _ in 0..<2 {
            let token = try peek()
            if case .anchor(let name) = token.kind, anchor == nil {
                try next(); anchor = name; sawProperty = true
            } else if case .tag(let spec) = token.kind, tag == nil {
                try next(); tag = try resolveTag(spec, token); sawProperty = true
            } else {
                break
            }
        }
        if let anchor {
            openAnchors.insert(anchor)
            anchors[anchor] = nil
        }
        let token = try peek()
        if sawProperty { start = first.start }
        var node: Node
        switch token.kind {
        case .blockEntry where indentlessSequence:
            node = try parseIndentlessSequence(depth: depth + 1)
        case .scalar(let text, let style):
            try next()
            node = Node(kind: .scalar(text, style), mark: token.start)
        case .flowSequenceStart:
            node = try parseFlowSequence(depth: depth + 1)
        case .flowMappingStart:
            node = try parseFlowMapping(depth: depth + 1)
        case .blockSequenceStart where block:
            node = try parseBlockSequence(depth: depth + 1)
        case .blockMappingStart where block:
            node = try parseBlockMapping(depth: depth + 1)
        default:
            guard sawProperty else {
                throw error("expected a node, but found \(token.kind.name)", token)
            }
            node = .empty(at: start)
        }
        node.tag = tag
        if tag != nil || anchor != nil { node.mark = start }
        if let anchor {
            openAnchors.remove(anchor)
            node.anchorID = nextAnchorID
            anchors[anchor] = nextAnchorID
            nextAnchorID += 1
        }
        return try countNode(node, depth: depth)
    }

    private func checkDepth(_ depth: Int, _ token: Token) throws(YAMLError) {
        if depth > limits.maxDepth {
            throw YAMLError(.depthLimitExceeded, "nesting is deeper than \(limits.maxDepth)", at: token.start)
        }
    }

    private mutating func emptyIfAt(_ kinds: (TokenKind) -> Bool, block: Bool, indentless: Bool, depth: Int) throws(YAMLError) -> Node {
        let token = try peek()
        if kinds(token.kind) { return try countNode(.empty(at: token.start), depth: depth) }
        return try parseNode(block: block, indentlessSequence: indentless, depth: depth)
    }

    private mutating func parseBlockSequence(depth: Int) throws(YAMLError) -> Node {
        let start = try next()
        try checkDepth(depth, start)
        var items: [Node] = []
        while true {
            let token = try peek()
            switch token.kind {
            case .blockEntry:
                try next()
                items.append(try emptyIfAt({ $0 == .blockEntry || $0 == .blockEnd }, block: true, indentless: false, depth: depth))
            case .blockEnd:
                try next()
                return Node(kind: .sequence(items), mark: start.start)
            default:
                throw error("expected '-' or end of block sequence, but found \(token.kind.name)", token)
            }
        }
    }

    private mutating func parseIndentlessSequence(depth: Int) throws(YAMLError) -> Node {
        let start = try peek()
        try checkDepth(depth, start)
        var items: [Node] = []
        while case .blockEntry = try peek().kind {
            try next()
            items.append(try emptyIfAt({ [.blockEntry, .key, .value, .blockEnd].contains($0) }, block: true, indentless: false, depth: depth))
        }
        return Node(kind: .sequence(items), mark: start.start)
    }

    private mutating func parseBlockMapping(depth: Int) throws(YAMLError) -> Node {
        let start = try next()
        try checkDepth(depth, start)
        var pairs: [(key: Node, value: Node)] = []
        let stop: (TokenKind) -> Bool = { $0 == .key || $0 == .value || $0 == .blockEnd }
        while true {
            let token = try peek()
            switch token.kind {
            case .key:
                try next()
                let key = try emptyIfAt(stop, block: true, indentless: true, depth: depth)
                let value: Node
                if case .value = try peek().kind {
                    try next()
                    value = try emptyIfAt(stop, block: true, indentless: true, depth: depth)
                } else {
                    value = try countNode(.empty(at: try peek().start), depth: depth)
                }
                pairs.append((key, value))
            case .value:
                try next()
                let key = try countNode(.empty(at: token.start), depth: depth)
                let value = try emptyIfAt(stop, block: true, indentless: true, depth: depth)
                pairs.append((key, value))
            case .blockEnd:
                try next()
                return Node(kind: .mapping(pairs), mark: start.start)
            default:
                throw error("expected a mapping key or end of block mapping, but found \(token.kind.name)", token)
            }
        }
    }

    /// Parses `? key : value`, `key: value` or `: value` inside a flow collection.
    private mutating func parseFlowPair(closing: TokenKind, depth: Int) throws(YAMLError) -> (key: Node, value: Node) {
        let token = try peek()
        let key: Node
        if case .key = token.kind {
            try next()
            key = try emptyIfAt({ $0 == .value || $0 == .flowEntry || $0 == closing }, block: false, indentless: false, depth: depth)
        } else if case .value = token.kind {
            key = try countNode(.empty(at: token.start), depth: depth)
        } else {
            key = try parseNode(block: false, indentlessSequence: false, depth: depth)
        }
        let value: Node
        if case .value = try peek().kind {
            try next()
            value = try emptyIfAt({ $0 == .flowEntry || $0 == closing }, block: false, indentless: false, depth: depth)
        } else {
            value = try countNode(.empty(at: try peek().start), depth: depth)
        }
        return (key, value)
    }

    private mutating func parseFlowSequence(depth: Int) throws(YAMLError) -> Node {
        let start = try next()
        try checkDepth(depth, start)
        var items: [Node] = []
        var first = true
        while true {
            var token = try peek()
            if case .flowSequenceEnd = token.kind { try next(); break }
            if !first {
                guard case .flowEntry = token.kind else {
                    throw error("expected ',' or ']' in flow sequence, but found \(token.kind.name)", token)
                }
                try next()
                token = try peek()
                if case .flowSequenceEnd = token.kind { try next(); break }
            }
            first = false
            switch token.kind {
            case .key, .value:
                let pair = try parseFlowPair(closing: .flowSequenceEnd, depth: depth + 1)
                try checkDepth(depth + 1, token)
                items.append(try countNode(Node(kind: .mapping([pair]), mark: token.start), depth: depth + 1))
            default:
                items.append(try parseNode(block: false, indentlessSequence: false, depth: depth))
            }
        }
        return Node(kind: .sequence(items), mark: start.start)
    }

    private mutating func parseFlowMapping(depth: Int) throws(YAMLError) -> Node {
        let start = try next()
        try checkDepth(depth, start)
        var pairs: [(key: Node, value: Node)] = []
        var first = true
        while true {
            var token = try peek()
            if case .flowMappingEnd = token.kind { try next(); break }
            if !first {
                guard case .flowEntry = token.kind else {
                    throw error("expected ',' or '}' in flow mapping, but found \(token.kind.name)", token)
                }
                try next()
                token = try peek()
                if case .flowMappingEnd = token.kind { try next(); break }
            }
            first = false
            pairs.append(try parseFlowPair(closing: .flowMappingEnd, depth: depth))
        }
        return Node(kind: .mapping(pairs), mark: start.start)
    }
}
