# Platform Support

Where Swift-YAML runs and how each platform is tested.

## Overview

| Platform | Status | CI |
|---|---|---|
| macOS 27+ | supported | `swift test` (debug and release), Xcode 27.2 |
| iOS 27+ | supported | built with Xcode 27.2 (`generic/platform=iOS`); same code as macOS, tests not run on device |
| Linux x86_64 and arm64 | supported | `swift test` (debug and release), `swift:6.4.2` container |
| WebAssembly (`wasm32-unknown-wasip1`) | supported | `swift test` (debug and release) under WasmKit, Swift 6.4.2 WASM SDK |

The Apple deployment minimums remain macOS 27 and iOS 27. Linux and WASI have no SwiftPM
platform entry. Swift 6.4 or later is required, in Swift 6 language mode.

The library uses only the Swift standard library and Swift-JSON's `JSON` module. It has
no Foundation, no C code and no threads, so it behaves the same on every platform. The
tests use Foundation only to locate the yaml-test-suite fixtures.

## Building for WebAssembly

Install the Swift.org toolchain and the matching WASM Swift SDK, as described in the
[Swift.org WebAssembly guide](https://www.swift.org/documentation/articles/wasm-getting-started.html).
Then build and test with the SDK:

```sh
swift build --swift-sdk swift-6.4.2-RELEASE_wasm
swift test --swift-sdk swift-6.4.2-RELEASE_wasm
```

The compiler and the SDK versions must match exactly. `swift test` runs the test binary
in WasmKit, which ships with the toolchain.
