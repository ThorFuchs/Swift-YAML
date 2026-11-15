# Mapping Rules

How YAML nodes become exact JSON values.

## Scalars

Only plain (unquoted) scalars are resolved, using the YAML 1.2 core schema:

| Plain scalar | Result |
|---|---|
| empty, `~`, `null`, `Null`, `NULL` | `null` |
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | boolean |
| `[-+]?[0-9]+`, `0o[0-7]+`, `0x[0-9a-fA-F]+` | exact integer |
| `[-+]?(\.[0-9]+ \| [0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?` | exact decimal |
| `.inf`, `-.inf`, `.nan` (any core spelling) | error ``YAMLError/Code-swift.enum/nonFiniteNumber`` |
| anything else | string with the exact source text |

Quoted scalars (`'…'`, `"…"`) and block scalars (`|`, `>`) are always strings.

YAML 1.1 forms stay strings. This covers `yes`, `no`, `on`, `off`, `1_000`, `0b101`,
sexagesimal numbers and timestamps such as `2001-12-14`.

Numbers keep their exact mathematical value. The resulting `JSONNumber.originalLexeme`
is the JSON spelling of that value, because some YAML spellings are not valid JSON:
`+12` becomes `12`, `007` becomes `7`, `.5` becomes `0.5`, `1.` becomes `1` and `0x1F`
becomes `31`. A number beyond Swift-JSON's balanced limits (4,096 digits, exponent
magnitude 1,000,000) is ``YAMLError/Code-swift.enum/numberOutOfRange``.

## Tags

| Tag | Effect |
|---|---|
| `!` | forces a string |
| `!!str` | forces a string |
| `!!int`, `!!float`, `!!bool`, `!!null` | the content must match the core-schema form for that type |
| `!!seq`, `!!map` | the node must be a sequence or a mapping |
| anything else | ``YAMLError/Code-swift.enum/unsupportedTag`` |

A core tag on content it cannot describe, such as `!!int abc` or `!!seq x`, is
``YAMLError/Code-swift.enum/invalidTaggedValue``. Local tags (`!foo`), `%TAG` prefixes
that resolve outside `tag:yaml.org,2002:`, and `!!binary`, `!!set`, `!!omap` and
`!!timestamp` are all unsupported.

## Mappings

- **Keys must be strings.** `1: a`, `true: a`, an empty key `: a` and complex keys
  (`[a]: b`) are ``YAMLError/Code-swift.enum/nonStringKey``. Quote a key (`"1": a`) to
  use it as a string.
- **Keys must be unique.** A repeated key is ``YAMLError/Code-swift.enum/duplicateKey``,
  reported at the second occurrence. Keys compare by Unicode scalars, the same rule as
  Swift-JSON.
- **Member order is source order.**
- **`<<` is an ordinary key**, because YAML 1.2 has no merge keys.

## Anchors and aliases

Aliases expand to the value of their anchor. An alias must come after its anchor in the
document. A recursive alias (`&a [*a]`) or an unknown name is
``YAMLError/Code-swift.enum/undefinedAlias``. An anchor may be redefined, and later
aliases use the newest definition.

Every expanded node counts against ``YAMLLimits/maxAliasExpansion``, ``YAMLLimits/maxNodes``
and ``YAMLLimits/maxDepth``. Exponential "billion laughs" inputs therefore fail quickly
instead of exhausting memory.

## Streams and directives

`---` starts a document and `...` ends one. `%YAML 1.x` and `%TAG` directives are honored
for the document that follows them. ``YAMLParser/parse(_:)-([UInt8])`` throws
``YAMLError/Code-swift.enum/multipleDocuments`` for a stream with more than one document.

## Input

Input must be UTF-8. A leading byte order mark is skipped. Characters outside YAML's
printable set, such as most C0 and C1 control characters, are
``YAMLError/Code-swift.enum/invalidEncoding``. CRLF and CR line breaks become LF in
scalar content.
