// SPDX-License-Identifier: Apache-2.0

/// Explicit resource ceilings. Exceeding any of them fails the parse; nothing is truncated.
public struct YAMLLimits: Sendable, Equatable {
    /// Maximum input size in bytes.
    public var maxInputBytes: Int
    /// Maximum nesting of sequences and mappings, measured on the expanded result.
    public var maxDepth: Int
    /// Maximum number of nodes (scalars, sequences, mappings and mapping keys) in the
    /// expanded result, counted across all documents of a stream.
    public var maxNodes: Int
    /// Maximum number of nodes that alias expansion may add, counted across the stream.
    public var maxAliasExpansion: Int

    /// Creates limits; every value must be positive.
    public init(
        maxInputBytes: Int = 8 * 1024 * 1024,
        maxDepth: Int = 64,
        maxNodes: Int = 1_000_000,
        maxAliasExpansion: Int = 100_000
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxAliasExpansion = maxAliasExpansion
    }

    /// 8 MiB input, depth 64, 1,000,000 nodes, 100,000 alias-expanded nodes.
    public static let `default` = YAMLLimits()
}
