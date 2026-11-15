# Working in Swift-YAML

A pure-Swift YAML 1.2 parser producing exact Swift-JSON values. README.md and the DocC
articles in `Sources/YAML/YAML.docc` are the specification; update them in the same commit
when behavior changes. TESTING.md is the test plan; CONTRIBUTING.md has the code rules.

- Swift 6 language mode, strict concurrency; public types are `Sendable`.
- No force unwraps or `fatalError` in library code. No Foundation in `Sources/`.
- Values are Swift-JSON `JSON`; numbers never go through `Double`. Missing, `null` and
  wrong kind stay distinct; no silent coercions or fallbacks.
- Nesting must never grow the call stack (parser and converter use explicit stacks).
- Errors are `YAMLError` with code, line and column; messages contain no paths.
- Tests use Swift Testing with behavior-named tests. Every `YAMLError.Code` has a
  negative test. The yaml-test-suite test must stay green; update `knownFailures` and the
  README together.
- Evidence is `swift test` (debug, release, WebAssembly) and `sh Tools/build-docc.sh`.
  No status or evidence files.
- Do not push, tag or publish without the owner's approval.
