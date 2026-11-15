# Test Plan

All tests use Swift Testing and live in `Tests/YAMLTests`. Each test name describes a
behavior. There are no skipped tests, no placeholder tests and no tests that only check
that code compiles.

## How to run

```sh
swift test                                         # debug
swift test -c release                              # release
swift test --swift-sdk swift-6.4.2-RELEASE_wasm    # WebAssembly, run under WasmKit
```

CI runs all of these on every push and pull request:

- macOS on Xcode 27.2, plus an iOS build
- Linux x86_64 and Linux arm64 in the `swift:6.4.2` container
- WebAssembly with the Swift 6.4.2 WASM SDK

CI also builds the DocC documentation with warnings treated as errors.

## What is tested where

| Area | Test suite (file) | What it guarantees |
|---|---|---|
| Specification conformance | `YAMLTestSuiteTests` | All 402 yaml-test-suite cases. Invalid YAML is rejected and valid YAML matches `in.json`; the 43 deliberate rejections are limited to the policy codes. Fails on any regression **and** on any newly passing known failure. |
| Error codes | `ErrorCodeCoverageTests` | Each `YAMLError.Code` case has a minimal reproducer that yields exactly that code with a valid position and a message without paths. The test is parameterized over `Code.allCases`, so a new code without a reproducer fails. |
| Core schema | `CoreSchemaTests` | null, boolean, integer (decimal, octal, hex) and float forms. Exact large integers and decimals, never `Double`. YAML 1.1 and non-core forms stay strings. Quoted and block scalars are never resolved. Missing, null and wrong kind stay distinct. |
| Tags | `TagTests` | Core tags force or check types. Custom and unknown tags fail. Tag and content mismatches fail. Undefined handles fail. |
| Numbers | `NumberErrorTests` | `.inf` and `.nan` fail. Over-long or over-large numbers fail. |
| Mappings | `MappingTests` | Source key order, duplicate keys with position, non-string keys, quoted numeric keys, `<<` as an ordinary key. |
| Structure | `StructureTests` | Block and flow nesting, block scalars with chomping and indentation indicators, quoted escapes and folding, comments, plain-scalar folding, aliases, anchor redefinition, BOM, CRLF. |
| Streams | `StreamTests` | Multi-document order, directives, empty streams and documents, `multipleDocuments`. |
| Syntax and encoding | `SyntaxErrorTests` | Positions, a catalog of malformed inputs, invalid UTF-8 and control characters, undefined and recursive aliases. |
| Limits | `LimitTests` | Each limit at and beyond its ceiling. Depth through aliases. Billion laughs. Depth 128 on a task thread. Cancellation. |
| Frontmatter | `FrontmatterTests` | Splitting, absence, CRLF, BOM, trailing blanks, empty blocks, unterminated fences, file-relative error lines. |

## Rules for changes

1. **Every behavior change comes with a test.** Change README.md and the DocC articles
   in the same pull request.
2. **Every new `YAMLError.Code` gets a reproducer** in `ErrorCodeCoverageTests` and a
   behavior test in the matching suite.
3. **Keep the yaml-test-suite at 0 known failures.** If a change makes a case fail,
   either fix it or add it to `knownFailures` with a reason, and list it in the README.
   CI fails on unexplained changes in either direction.
4. **Test inputs are small strings written in the test.** Only the yaml-test-suite lives in
   `Fixtures/`. Its files are copied unmodified.
5. **Limit and safety tests use tiny limits** so that they run fast on every platform,
   including WebAssembly.
