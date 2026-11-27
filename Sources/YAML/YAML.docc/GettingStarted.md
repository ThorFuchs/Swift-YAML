# Getting Started

Add the package, parse a document, and read the result as JSON.

## Add the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ThorFuchs/Swift-YAML.git", from: "0.1.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "YAML", package: "Swift-YAML"),
        .product(name: "JSON", package: "Swift-JSON"),
    ]),
]
```

Swift-YAML depends on Swift-JSON 1.9.0..<1.11.0, which SwiftPM resolves automatically; 1.9.0 and 1.10.0 are tested.

## Parse one document

``YAMLParser/parse(_:)-([UInt8])`` accepts a stream with at most one document:

```swift
import JSON
import YAML

let config = try YAMLParser().parse("""
    site: Example
    port: 8080
    ratio: 0.1
    tags: [news, blog]
    """)

config.objectValue?["port"]          // .number(8080)
config.objectValue?["ratio"]         // .number(0.1), exact, not a Double
config.objectValue?["missing"]       // nil: absent, not null
```

An empty input, or an input containing only comments, parses to `.null`.

## Parse a stream

``YAMLParser/parseStream(_:)-([UInt8])`` returns every document in order:

```swift
let records = try YAMLParser().parseStream("""
    --- {id: a}
    --- {id: b}
    """)
records.count  // 2
```

## Handle errors

Every failure is a ``YAMLError`` with a stable ``YAMLError/Code-swift.enum``, a message
and a 1-based line and column:

```swift
do {
    _ = try YAMLParser().parse("a: 1\na: 2\n")
} catch {
    error.code         // .duplicateKey
    error.description  // "2:1: duplicate mapping key \"a\""
}
```

The `parse` methods use typed throws, so `error` is a ``YAMLError`` without casting.
