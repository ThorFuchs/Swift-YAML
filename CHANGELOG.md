# Changelog

This project follows [Semantic Versioning](https://semver.org). Before 1.0.0, minor
releases may change the public API.

## 0.1.1

- Admit Swift-JSON 1.9.0..<1.11.0; qualify 1.9.0 and 1.10.0.
- Preserve the public API, format semantics and deployment floors.

## 0.1.0

First public release.

- `YAMLParser` parses YAML 1.2 into exact Swift-JSON 1.9.0 values, using the core schema:
  - `parse` for at most one document;
  - `parseStream` for multi-document streams;
  - `parseFrontmatter` for Markdown frontmatter.
- `YAMLFrontmatter.split` separates frontmatter from the body, with file-relative line
  numbers.
- `YAMLLimits` bounds input bytes, depth, nodes and alias expansion. Cancellation is
  supported.
- `YAMLError` reports 16 stable codes with a 1-based line and column.
- All 402 yaml-test-suite cases (data-2022-01-17) are run: 0 known failures, and 43
  documented rejections of YAML that JSON cannot represent.
- Tested on macOS, Linux x86_64 and arm64, and WebAssembly (WASI).
