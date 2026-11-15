# Swift-YAML

**A pure-Swift YAML 1.2 parser that produces exact [Swift-JSON](https://github.com/ThorFuchs/Swift-JSON) values.**

Swift-YAML reads YAML data files and Markdown frontmatter into Swift-JSON `JSON` values,
using the YAML 1.2 core schema. Numbers stay exact decimals and never pass through
`Double`. Missing, `null` and wrong-kind values stay distinct. Anything JSON cannot
represent is an error rather than a silent conversion. No C code, no Foundation in the
library target. It builds on macOS and Linux.

The first consumer is Swift Content Collections. Its `Documentation/SPEC.md` §6 sets the
mapping rules this package implements. This README is the package's only specification.

## Usage

```swift
.package(url: "https://github.com/ThorFuchs/Swift-YAML.git", branch: "main"),  // not yet tagged
// target dependency:
.product(name: "YAML", package: "Swift-YAML"),
```

```swift
import JSON
import YAML

let parser = YAMLParser()                        // YAMLLimits.default
let value: JSON = try parser.parse("title: Hello\ncount: 3\n")
let documents: [JSON] = try parser.parseStream("--- {a: 1}\n--- {a: 2}\n")

if let front = try parser.parseFrontmatter(markdownBytes) {
    front.data            // JSON (.null for an empty block)
    front.body            // [UInt8] after the closing fence
    front.bodyStartLine   // 1-based line of the first body line
}
```

## Public API

```swift
public struct YAMLParser: Sendable {
    public var limits: YAMLLimits
    public init(limits: YAMLLimits = .default)
    public func parse(_ bytes: [UInt8]) throws(YAMLError) -> JSON          // 0 or 1 document; 0 → .null
    public func parse(_ text: String) throws(YAMLError) -> JSON
    public func parseStream(_ bytes: [UInt8]) throws(YAMLError) -> [JSON]  // every document, in order; empty → []
    public func parseStream(_ text: String) throws(YAMLError) -> [JSON]
    public func parseFrontmatter(_ bytes: [UInt8]) throws(YAMLError) -> ParsedFrontmatter?  // nil: no frontmatter
}

public struct ParsedFrontmatter: Sendable, Equatable {
    public let data: JSON
    public let body: [UInt8]
    public let bodyStartLine: Int
}

public struct YAMLFrontmatter: Sendable, Equatable {        // split only, no parsing
    public let yaml: [UInt8]
    public let yamlStartLine: Int
    public let body: [UInt8]
    public let bodyStartLine: Int
    public static func split(_ bytes: [UInt8]) throws(YAMLError) -> YAMLFrontmatter?
}

public struct YAMLLimits: Sendable, Equatable {
    public var maxInputBytes: Int      // default 8 MiB
    public var maxDepth: Int           // default 128, measured on the alias-expanded result
    public var maxNodes: Int           // default 1,000,000, expanded result, cumulative over a stream
    public var maxAliasExpansion: Int  // default 100,000 nodes added by aliases, cumulative
    public static let `default`: YAMLLimits
}

public struct YAMLError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, CaseIterable {
        case invalidEncoding, syntax, duplicateKey, nonStringKey, unsupportedTag, invalidTaggedValue,
             nonFiniteNumber, numberOutOfRange, undefinedAlias, multipleDocuments,
             unterminatedFrontmatter, inputTooLarge, depthLimitExceeded, nodeLimitExceeded,
             aliasExpansionLimitExceeded, cancelled
    }
    public let code: Code
    public let message: String         // never contains a path
    public let line: Int               // 1-based
    public let column: Int             // 1-based, in Unicode scalars
    public func shifted(byLines: Int) -> YAMLError
}
```

## Semantics

**Scalars (YAML 1.2 core schema).** Only plain scalars are resolved:

| Plain scalar | Result |
|---|---|
| empty, `~`, `null`, `Null`, `NULL` | `null` |
| `true`/`True`/`TRUE`, `false`/`False`/`FALSE` | boolean |
| `[-+]?[0-9]+`, `0o[0-7]+`, `0x[0-9a-fA-F]+` | exact integer |
| `[-+]?(\.[0-9]+ \| [0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?` | exact decimal |
| `.inf`, `-.inf`, `.nan` (any core spelling) | error `nonFiniteNumber` |
| anything else (timestamps, `yes`, `1_000`, `0b1`, `1.2.3`) | string, exact source text |

Quoted and block scalars are always strings. Numbers keep their exact value. Their
`JSONNumber.originalLexeme` is the JSON spelling of that value, because some YAML
spellings are not valid JSON: `+12` → `12`, `007` → `7`, `.5` → `0.5`, `1.` → `1`,
`0x1F` → `31`.

**Tags.** `!` (non-specific) forces a string. `!!str`, `!!int`, `!!float`, `!!bool`,
`!!null`, `!!seq` and `!!map` force or check the type. A mismatch such as `!!int abc` is
`invalidTaggedValue`. Every other tag, local or global (`!foo`, `!!binary`,
`!!timestamp`, `!!set`, `!!omap`, `%TAG`-prefixed), is `unsupportedTag`.

**Mappings.** Keys must resolve to strings. `1: a`, `true: a`, `: a` (null key) and
complex keys are `nonStringKey`. Quote them (`"1": a`) to use them as strings.
Duplicate keys are `duplicateKey`. Keys compare by Unicode scalars, the same rule as
Swift-JSON. Member order is source order. `<<` is an ordinary key, because YAML 1.2
has no merge keys.

**Anchors and aliases** are expanded. An alias must follow its anchor, and recursive
aliases are `undefinedAlias`. An anchor may be redefined; later aliases use the newest
definition. Expansion counts against `maxAliasExpansion`, `maxNodes` and `maxDepth`, so
"billion laughs" inputs fail fast.

**Streams.** `---` and `...` separate documents, and `%YAML 1.x` and `%TAG` directives
are honored. `parse` requires at most one document and throws `multipleDocuments`
otherwise. An empty stream or an empty document parses to `.null`. Use `parseStream`
when you need to tell them apart.

**Input.** UTF-8 only, with an optional byte order mark. Characters outside YAML's
printable set are `invalidEncoding`. CRLF and CR line breaks are normalized to LF in
scalar content.

**Frontmatter.** It exists only when the first line, after an optional BOM, is `---`,
with optional trailing blanks and an LF or CRLF line ending. It ends at the next `---`
line. A missing closing fence is `unterminatedFrontmatter`. Error lines from
`parseFrontmatter` refer to the whole file.

**Limits and cancellation.** Exceeding a limit throws. The parser never truncates.
Parsing and conversion use explicit stacks, so `maxDepth` 128 is safe on 512 KB task
threads even in debug builds. The parser checks `Task.isCancelled` at entry and every
1,024 nodes, and throws `cancelled`.

## Conformance: yaml-test-suite

`Tests/YAMLTests/Fixtures/yaml-test-suite` holds all 402 cases of the official
[YAML Test Suite](https://github.com/yaml/yaml-test-suite), release `data-2022-01-17`
(MIT). `swift test` runs every case:

- **94/94 invalid cases** are rejected, all with `syntax`.
- **265/265 valid cases** that JSON can represent parse. Where the suite provides
  `in.json`, the result equals it.
- **43 valid cases are rejected on purpose**, because JSON cannot represent them:
  - **Non-string or empty keys** (27, `nonStringKey`): 2JQS 4FJ6 6BFJ 6M2F 6PBE 9MMW CFD4 DFF7 FH7J
    FRK4 KK5P LX3P M2N8-00 M2N8-01 M5DY NHX8 NKF9 PW8X Q9WF RZP5 S3PD SBG9 SM9W-01 UKK6-00
    V9D5 X38W XW4D.
  - **Custom or non-core tags** (16, `unsupportedTag`): 2XXW 565N 5TYM 6CK3 6WLZ 7FWL 9WXW C4HZ CC74
    CUP7 J7PZ M5C3 P76L UGM3 Z67P Z9M4.
- **Known failures:** none. The test fails if a case regresses or if a listed
  failure starts passing.

The suite does not check comment placement or exact error positions. Positions are
covered by the unit tests.

## Not supported (by design)

- YAML 1.1 schema features: `yes`/`no`/`on`/`off` booleans, sexagesimal numbers,
  `<<` merge keys, typed timestamps. They stay strings.
- Custom tags, `!!binary`, `!!set`, `!!omap`, `!!timestamp`.
- Non-string mapping keys and complex keys.
- UTF-16 and UTF-32 input.
- Implicit keys longer than 1,024 characters or spanning lines (a YAML 1.2 rule).
- Serializing (emitting) YAML.

## Development

```bash
swift build
swift test
swift test -c release
```

Green `swift test` is the evidence. The work is tracked in Git history, with no status
files. In release builds the parser converts about 3–5 MB/s of typical content.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The yaml-test-suite fixtures
are MIT-licensed; see their `LICENSE` file.
