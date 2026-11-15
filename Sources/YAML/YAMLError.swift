// SPDX-License-Identifier: Apache-2.0

/// A YAML failure with a stable code and the 1-based source position where it was detected.
///
/// Messages never contain file paths; callers add their own context.
public struct YAMLError: Error, Sendable, Equatable, CustomStringConvertible {
    /// What went wrong. New cases may be added in minor releases; switch with `default`.
    public enum Code: String, Sendable, Equatable, CaseIterable {
        /// The input is not valid UTF-8 or contains a character YAML does not allow.
        case invalidEncoding
        /// The input does not follow the YAML 1.2 grammar.
        case syntax
        /// A mapping repeats a key.
        case duplicateKey
        /// A mapping key does not resolve to a string.
        case nonStringKey
        /// A tag outside the supported core-schema set (`!`, `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq`, `!!map`).
        case unsupportedTag
        /// A core-schema tag was applied to content it cannot describe, such as `!!int abc`.
        case invalidTaggedValue
        /// `.inf`, `-.inf` or `.nan`, which JSON cannot represent.
        case nonFiniteNumber
        /// A number has more digits or a larger exponent than Swift-JSON's balanced limits allow.
        case numberOutOfRange
        /// An alias names an anchor that is not defined before it, or that refers to itself.
        case undefinedAlias
        /// `parse` was given a stream with more than one document.
        case multipleDocuments
        /// A frontmatter block opened with `---` was never closed.
        case unterminatedFrontmatter
        /// The input is larger than `YAMLLimits.maxInputBytes`.
        case inputTooLarge
        /// Nesting is deeper than `YAMLLimits.maxDepth`.
        case depthLimitExceeded
        /// The result has more nodes than `YAMLLimits.maxNodes`.
        case nodeLimitExceeded
        /// Alias expansion produced more nodes than `YAMLLimits.maxAliasExpansion`.
        case aliasExpansionLimitExceeded
        /// The surrounding task was cancelled.
        case cancelled
    }

    /// The failure category.
    public let code: Code
    /// A short human-readable explanation.
    public let message: String
    /// The 1-based line of the failure.
    public let line: Int
    /// The 1-based column of the failure, counted in Unicode scalars.
    public let column: Int

    /// Creates an error value.
    public init(_ code: Code, _ message: String, line: Int, column: Int) {
        self.code = code
        self.message = message
        self.line = line
        self.column = column
    }

    /// `line:column: message`.
    public var description: String { "\(line):\(column): \(message)" }

    /// The same error moved down by `lines`, used when YAML is embedded in a larger file.
    public func shifted(byLines lines: Int) -> YAMLError {
        YAMLError(code, message, line: line + lines, column: column)
    }
}

/// A 0-based position in the decoded scalar buffer.
struct Mark: Sendable, Equatable {
    var index: Int
    var line: Int
    var column: Int

    static let start = Mark(index: 0, line: 0, column: 0)
}

extension YAMLError {
    init(_ code: Code, _ message: String, at mark: Mark) {
        self.init(code, message, line: mark.line + 1, column: mark.column + 1)
    }
}
