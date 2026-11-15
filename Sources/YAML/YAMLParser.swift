// SPDX-License-Identifier: Apache-2.0
import JSON

/// Parses YAML 1.2 into exact Swift-JSON values using the core schema.
///
/// - Plain scalars resolve to null, booleans, integers (decimal, `0o`, `0x`) and floats;
///   everything else, including timestamps, stays a string with its exact text.
/// - Numbers become exact `JSONNumber` values; they never pass through `Double`.
/// - Mapping keys must be strings and must be unique; member order is source order.
/// - Anchors and aliases are expanded within `YAMLLimits.maxAliasExpansion`.
/// - Tags other than `!`, `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq` and `!!map` are errors.
public struct YAMLParser: Sendable {
    /// The limits applied to every call.
    public var limits: YAMLLimits

    /// Creates a parser with the given limits.
    public init(limits: YAMLLimits = .default) {
        self.limits = limits
    }

    /// Parses a stream that holds at most one document.
    ///
    /// An empty stream (no documents, for example only comments) yields `.null`, as does an empty document.
    /// - Throws: `YAMLError`; `.multipleDocuments` if the stream has more than one document.
    public func parse(_ bytes: [UInt8]) throws(YAMLError) -> JSON {
        let roots = try parseNodes(bytes)
        guard roots.count <= 1 else {
            throw YAMLError(.multipleDocuments, "expected a single document, found \(roots.count)", at: roots[1].mark)
        }
        guard let root = roots.first else { return .null }
        var converter = Converter(limits: limits)
        return try converter.convert(root)
    }

    /// Parses UTF-8 text that holds at most one document. See `parse(_:)` for bytes.
    public func parse(_ text: String) throws(YAMLError) -> JSON {
        try parse(Array(text.utf8))
    }

    /// Parses every document of a stream, in order. An empty stream yields `[]`.
    public func parseStream(_ bytes: [UInt8]) throws(YAMLError) -> [JSON] {
        let roots = try parseNodes(bytes)
        var converter = Converter(limits: limits)
        var documents: [JSON] = []
        documents.reserveCapacity(roots.count)
        for root in roots {
            documents.append(try converter.convert(root))
        }
        return documents
    }

    /// Parses every document of UTF-8 text. See `parseStream(_:)` for bytes.
    public func parseStream(_ text: String) throws(YAMLError) -> [JSON] {
        try parseStream(Array(text.utf8))
    }

    private func parseNodes(_ bytes: [UInt8]) throws(YAMLError) -> [Node] {
        guard bytes.count <= limits.maxInputBytes else {
            throw YAMLError(.inputTooLarge, "input is larger than \(limits.maxInputBytes) bytes", line: 1, column: 1)
        }
        if Task.isCancelled { throw YAMLError(.cancelled, "parsing was cancelled", line: 1, column: 1) }
        let scalars = try decodeYAMLInput(bytes)
        var parser = Parser(scalars, limits: limits)
        return try parser.parseStream()
    }
}
