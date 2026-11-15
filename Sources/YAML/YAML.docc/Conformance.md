# Conformance

How Swift-YAML is checked against the YAML specification.

## yaml-test-suite

The test target contains all 402 cases of the official
[YAML Test Suite](https://github.com/yaml/yaml-test-suite), release `data-2022-01-17`.
Every run of `swift test` executes all of them on every platform:

| Category | Cases | Result |
|---|---|---|
| Invalid YAML | 94 | all rejected with ``YAMLError/Code-swift.enum/syntax`` |
| Valid YAML that JSON can represent | 265 | all parsed; equal to the suite's `in.json` where it has one |
| Valid YAML that JSON cannot represent | 43 | rejected on purpose (see below) |
| Known failures | 0 | the test fails on any regression |

The 43 deliberate rejections fall into two groups:

- 27 cases use non-string, empty or complex mapping keys
  (``YAMLError/Code-swift.enum/nonStringKey``).
- 16 cases use custom or non-core tags (``YAMLError/Code-swift.enum/unsupportedTag``).

The repository README lists each case ID.

The suite does not check error positions. Those are covered by the unit tests, which
are described in the repository's `TESTING.md`.
