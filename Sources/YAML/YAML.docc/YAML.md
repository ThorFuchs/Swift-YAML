# ``YAML``

Parse YAML 1.2 into exact Swift-JSON values.

## Overview

Swift-YAML reads YAML data files, multi-document streams and Markdown frontmatter into
[Swift-JSON](https://github.com/ThorFuchs/Swift-JSON) `JSON` values. It follows the YAML 1.2
core schema. Numbers stay exact decimals and never pass through `Double`. Missing, `null`
and wrong-kind values stay distinct, and anything JSON cannot represent is an error rather
than a silent conversion.

The package is pure Swift, with no C code and no Foundation in the library. It runs on
macOS, iOS, Linux and WebAssembly (WASI).

```swift
import JSON
import YAML

let value = try YAMLParser().parse("title: Hello\ncount: 3\n")
// {"title": "Hello", "count": 3}
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``YAMLParser``

### Mapping YAML to JSON

- <doc:MappingRules>

### Frontmatter

- <doc:Frontmatter>
- ``YAMLFrontmatter``
- ``ParsedFrontmatter``

### Limits and errors

- <doc:LimitsAndErrors>
- ``YAMLLimits``
- ``YAMLError``

### Quality

- <doc:PlatformSupport>
- <doc:Conformance>
