# Limits and Errors

Explicit ceilings that fail instead of degrading, and errors you can act on.

## Limits

``YAMLLimits`` bounds every call:

| Limit | Default | Error |
|---|---|---|
| ``YAMLLimits/maxInputBytes`` | 8 MiB | ``YAMLError/Code-swift.enum/inputTooLarge`` |
| ``YAMLLimits/maxDepth`` | 128 | ``YAMLError/Code-swift.enum/depthLimitExceeded`` |
| ``YAMLLimits/maxNodes`` | 1,000,000 | ``YAMLError/Code-swift.enum/nodeLimitExceeded`` |
| ``YAMLLimits/maxAliasExpansion`` | 100,000 | ``YAMLError/Code-swift.enum/aliasExpansionLimitExceeded`` |

Depth and node counts are measured on the result after alias expansion. Node counts are
cumulative across all documents of a stream. A result is never truncated: the call either
returns the complete value or throws.

Parsing and conversion use explicit stacks rather than recursion. Deep nesting up to the
limit is therefore safe on small thread stacks, including 512 KB task threads in debug
builds.

## Cancellation

The parser checks `Task.isCancelled` on entry and every 1,024 nodes. It throws
``YAMLError/Code-swift.enum/cancelled`` when the surrounding task is cancelled.

## Errors

``YAMLError`` carries a ``YAMLError/code-swift.property``, a
``YAMLError/message``, and a 1-based ``YAMLError/line`` and ``YAMLError/column``.
Columns count Unicode scalars. Messages never contain file paths, so callers add their
own context. Use ``YAMLError/shifted(byLines:)`` when the YAML is embedded in a larger
file.

New codes may be added in minor releases, so `switch` over ``YAMLError/Code-swift.enum``
with a `default` case.
