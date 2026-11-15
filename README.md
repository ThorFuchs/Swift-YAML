# Swift-YAML

**A pure-Swift YAML 1.2 parser that produces exact [Swift-JSON](https://github.com/ThorFuchs/Swift-JSON) values.**

[![CI](https://github.com/ThorFuchs/Swift-YAML/actions/workflows/ci.yml/badge.svg)](https://github.com/ThorFuchs/Swift-YAML/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platforms: macOS | iOS | Linux | WebAssembly](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20Linux%20%7C%20WebAssembly-lightgrey.svg)

[Read the documentation →](https://thorfuchs.github.io/Swift-YAML/documentation/yaml/)

Swift-YAML reads YAML data files, multi-document streams and Markdown frontmatter into
Swift-JSON `JSON` values. It uses the YAML 1.2 core schema. Numbers stay exact decimals
and never pass through `Double`. Missing, `null` and wrong-kind values stay distinct.
Anything JSON cannot represent is an error rather than a silent conversion.

- **Exact values.** `9007199254740993` stays `9007199254740993`, and `0.1` stays exactly `0.1`.
- **No surprises.** `yes`, `no` and `2001-12-14` stay strings. Duplicate keys, custom tags
  and `.inf` are errors.
- **Safe on untrusted input.** Explicit limits on input size, depth, nodes and alias
  expansion. It has no recursion, so it is safe against "billion laughs" and stack
  exhaustion.
- **Portable.** Pure Swift: no C code and no Foundation in the library. It is tested on
  macOS, Linux (x86_64 and arm64) and WebAssembly (WASI).
- **Conformant.** It runs all 402 cases of the official yaml-test-suite on every platform,
  with 0 known failures.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ThorFuchs/Swift-YAML.git", from: "0.1.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "YAML", package: "Swift-YAML"),
        .product(name: "JSON", package: "Swift-JSON"),  // to work with the results
    ]),
]
```

| Requirement | Supported |
|---|---|
| Swift | 6.4 or later, Swift 6 language mode |
| Apple platforms | macOS 27, iOS 27 and later (the minimums of Swift-JSON 1.9.0); iOS is built in CI |
| Linux | x86_64 and arm64 |
| WebAssembly | `wasm32-unknown-wasip1` with the matching Swift.org WASM SDK |
| Dependencies | [Swift-JSON](https://github.com/ThorFuchs/Swift-JSON) 1.9.0 |

## Usage

```swift
import JSON
import YAML

let parser = YAMLParser()                                  // YAMLLimits.default

// One document
let config = try parser.parse("site: Example\nport: 8080\nratio: 0.1\n")
config.objectValue?["port"]                                // .number(8080)

// A stream of documents
let records = try parser.parseStream("--- {id: a}\n--- {id: b}\n")

// Markdown frontmatter
if let front = try parser.parseFrontmatter(Array(markdown.utf8)) {
    front.data            // JSON (.null for an empty block)
    front.body            // [UInt8] after the closing fence
    front.bodyStartLine   // 1-based line of the first body line
}

// Errors are typed, positioned and stable
do {
    _ = try parser.parse("a: 1\na: 2\n")
} catch {
    print(error.code, error.line, error.column)            // duplicateKey 2 1
}
```

## How YAML maps to JSON

| YAML | JSON |
|---|---|
| `null`, `Null`, `NULL`, `~`, empty | `null` |
| `true`/`True`/`TRUE`, `false`/`False`/`FALSE` | boolean |
| `42`, `-7`, `+3`, `007`, `0o17`, `0x1F` | exact integer |
| `1.5`, `.5`, `1.`, `6.02e23` | exact decimal |
| `.inf`, `-.inf`, `.nan` | error `nonFiniteNumber` |
| any other plain scalar, including timestamps | string with the exact source text |
| quoted or block scalars | string |
| `!`, `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq`, `!!map` | type forced or checked |
| any other tag | error `unsupportedTag` |
| mapping with string keys | object, in source order |
| non-string key (`1: a`, `: a`, `[a]: b`) | error `nonStringKey` |
| repeated key | error `duplicateKey` |
| anchors and aliases | expanded, within `maxAliasExpansion` |

See [Mapping Rules](https://thorfuchs.github.io/Swift-YAML/documentation/yaml/mappingrules)
for the details, including how numbers are spelled.

## Limits and errors

| Limit | Default | Error |
|---|---|---|
| `maxInputBytes` | 8 MiB | `inputTooLarge` |
| `maxDepth` | 128 | `depthLimitExceeded` |
| `maxNodes` | 1,000,000 | `nodeLimitExceeded` |
| `maxAliasExpansion` | 100,000 | `aliasExpansionLimitExceeded` |

Every failure is a `YAMLError` with a `code`, a `message` without file paths, and a
1-based `line` and `column`. The full list of codes is in the
[documentation](https://thorfuchs.github.io/Swift-YAML/documentation/yaml/yamlerror/code-swift.enum).
Cancelling the surrounding task stops a parse with `cancelled`.

## Conformance

The tests contain all 402 cases of the [YAML Test Suite](https://github.com/yaml/yaml-test-suite)
(release `data-2022-01-17`), and every CI run executes them on every platform:

- **Invalid YAML (94 cases):** all rejected with `syntax`.
- **Valid YAML that JSON can represent (265 cases):** all parsed. Where the suite gives an
  expected `in.json`, the result equals it.
- **Valid YAML that JSON cannot represent (43 cases):** rejected on purpose.
  - Non-string, empty or complex keys (27, `nonStringKey`): 2JQS 4FJ6 6BFJ 6M2F 6PBE 9MMW
    CFD4 DFF7 FH7J FRK4 KK5P LX3P M2N8-00 M2N8-01 M5DY NHX8 NKF9 PW8X Q9WF RZP5 S3PD SBG9
    SM9W-01 UKK6-00 V9D5 X38W XW4D.
  - Custom or non-core tags (16, `unsupportedTag`): 2XXW 565N 5TYM 6CK3 6WLZ 7FWL 9WXW
    C4HZ CC74 CUP7 J7PZ M5C3 P76L UGM3 Z67P Z9M4.
- **Known failures:** none.

## Not supported, by design

- YAML 1.1 schema features: `yes`/`no`/`on`/`off` booleans, sexagesimal numbers, `<<`
  merge keys, typed timestamps. They stay strings or ordinary keys.
- Custom tags and `!!binary`, `!!set`, `!!omap`, `!!timestamp`.
- Non-string mapping keys and complex keys.
- UTF-16 and UTF-32 input.
- Implicit keys longer than 1,024 characters or spanning lines (a YAML 1.2 rule).
- Writing (emitting) YAML.

## Documentation

- [API reference and guides](https://thorfuchs.github.io/Swift-YAML/documentation/yaml/),
  built with DocC from `Sources/YAML/YAML.docc`
- [TESTING.md](TESTING.md): the test plan
- [CONTRIBUTING.md](CONTRIBUTING.md): how to build, test and propose changes
- [CHANGELOG.md](CHANGELOG.md): release history
- [SECURITY.md](SECURITY.md): how to report a vulnerability

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The vendored yaml-test-suite
fixtures are MIT-licensed; see
[their license](Tests/YAMLTests/Fixtures/yaml-test-suite/LICENSE).
