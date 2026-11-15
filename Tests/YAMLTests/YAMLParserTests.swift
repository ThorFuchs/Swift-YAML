// SPDX-License-Identifier: Apache-2.0
import JSON
import Testing
import YAML

func yaml(_ text: String, limits: YAMLLimits = .default) throws -> JSON {
    try YAMLParser(limits: limits).parse(text)
}

func json(_ text: String) throws -> JSON {
    try JSON.parse(text)
}

func yamlError(_ text: String, limits: YAMLLimits = .default) -> YAMLError? {
    do {
        _ = try YAMLParser(limits: limits).parseStream(text)
        return nil
    } catch {
        return error
    }
}

struct CoreSchemaTests {
    @Test("plain null forms resolve to null, quoted ones stay strings")
    func nulls() throws {
        #expect(try yaml("a: null\nb: Null\nc: NULL\nd: ~\ne:\nf: 'null'") ==
                json(#"{"a":null,"b":null,"c":null,"d":null,"e":null,"f":"null"}"#))
    }

    @Test("only core-schema booleans are booleans; YAML 1.1 yes/no/on/off stay strings")
    func booleans() throws {
        #expect(try yaml("[true, True, TRUE, false, False, FALSE, yes, no, on, off, tRue]") ==
                json(#"[true,true,true,false,false,false,"yes","no","on","off","tRue"]"#))
    }

    @Test("integers: decimal with sign and leading zeros, 0o octal, 0x hexadecimal")
    func integers() throws {
        #expect(try yaml("[0, -17, +42, 007, 0o17, 0x1F, 0xff]") == json("[0,-17,42,7,15,31,255]"))
    }

    @Test("large integers stay exact and never pass through Double")
    func exactIntegers() throws {
        let value = try yaml("n: 9007199254740993")
        let expected = try JSON.number(parsing: "9007199254740993")
        #expect(value.objectValue?["n"] == expected)
        #expect(value.objectValue?["n"] != (try JSON.number(parsing: "9007199254740992")))
        let hex = try yaml("0xFFFFFFFFFFFFFFFFFFFF")
        #expect(hex == (try JSON.number(parsing: "1208925819614629174706175")))
    }

    @Test("floats keep their exact decimal value")
    func floats() throws {
        let value = try yaml("[1.5, -0.25, .5, 1., +12e3, 6.02E+23, 0.1]")
        #expect(value == (try json("[1.5,-0.25,0.5,1,12e3,6.02e23,0.1]")))
        #expect(value.arrayValue?[6].numberValue?.originalLexeme == "0.1")
        #expect(value.arrayValue?[2].numberValue?.originalLexeme == "0.5")
    }

    @Test("timestamps, versions and other non-core scalars stay strings with exact text")
    func nonCoreScalars() throws {
        #expect(try yaml("[2001-12-14t21:59:43.10-05:00, 2002-12-14, 1.2.3, 0b101, 1_000, 0x, 12:30, .Nan1]") ==
                json(#"["2001-12-14t21:59:43.10-05:00","2002-12-14","1.2.3","0b101","1_000","0x","12:30",".Nan1"]"#))
    }

    @Test("quoted and block scalars are never resolved")
    func quotedStaysString() throws {
        #expect(try yaml("a: '1'\nb: \"true\"\nc: |\n  42\n") == json(#"{"a":"1","b":"true","c":"42\n"}"#))
    }

    @Test("missing key, null value and wrong kind stay distinct")
    func missingNullWrongKind() throws {
        let value = try yaml("present: null\nnumber: 1\ntext: '1'")
        let object = try #require(value.objectValue)
        #expect(object["absent"] == nil)
        #expect(object["present"] == .null)
        #expect(object["number"]?.numberValue != nil)
        #expect(object["text"] == .string("1"))
    }
}

struct TagTests {
    @Test("core tags force or check the type")
    func coreTags() throws {
        #expect(try yaml("[!!str 1, !!int '12', !!float 3, !!bool 'true', !!null '', ! 7, !<tag:yaml.org,2002:str> x]") ==
                json(#"["1",12,3,true,null,"7","x"]"#))
        #expect(try yaml("!!map {a: !!seq [1]}") == json(#"{"a":[1]}"#))
    }

    @Test("custom and unknown tags are an error")
    func unsupportedTags() {
        for text in ["!foo bar", "!!binary aGVsbG8=", "!!timestamp 2001-01-01", "!!set {a}", "%TAG !e! tag:example.com:\n---\n!e!x 1", "- !local [1]"] {
            #expect(yamlError(text)?.code == .unsupportedTag, "\(text)")
        }
    }

    @Test("core tags on content they cannot describe are an error")
    func invalidTaggedValues() {
        for text in ["!!int abc", "!!int 1.5", "!!bool yes", "!!null 0", "!!float x", "!!str [1]", "!!seq {a: 1}", "!!map [1]", "!!seq x"] {
            #expect(yamlError(text)?.code == .invalidTaggedValue, "\(text)")
        }
    }

    @Test("undefined tag handle is a syntax error")
    func undefinedHandle() {
        #expect(yamlError("!e!x 1")?.code == .syntax)
    }
}

struct NumberErrorTests {
    @Test(".inf and .nan are errors because JSON cannot represent them")
    func nonFinite() {
        for text in [".inf", "-.Inf", "+.INF", ".nan", ".NaN", "x: !!float .inf"] {
            #expect(yamlError(text)?.code == .nonFiniteNumber, "\(text)")
        }
    }

    @Test("numbers beyond Swift-JSON's exact limits are an error")
    func outOfRange() {
        #expect(yamlError(String(repeating: "9", count: 5000))?.code == .numberOutOfRange)
        #expect(yamlError("0x" + String(repeating: "F", count: 3001))?.code == .numberOutOfRange)
        #expect(yamlError("1e99999999")?.code == .numberOutOfRange)
    }
}

struct MappingTests {
    @Test("key order is source order")
    func keyOrder() throws {
        let value = try yaml("zebra: 1\napple: 2\nmango: 3\n")
        #expect(value.objectValue?.members.map(\.key.string) == ["zebra", "apple", "mango"])
    }

    @Test("duplicate keys are an error with the position of the second key")
    func duplicateKeys() throws {
        let error = try #require(yamlError("a: 1\nb: 2\na: 3\n"))
        #expect(error.code == .duplicateKey)
        #expect(error.line == 3 && error.column == 1)
        #expect(yamlError("{a: 1, 'a': 2}")?.code == .duplicateKey)
        #expect(yamlError("x: 1\n\"x\": 2")?.code == .duplicateKey)
    }

    @Test("keys that are not strings are an error, including numbers, booleans, null and collections")
    func nonStringKeys() {
        for text in ["1: a", "true: a", "null: a", ": a", "[a]: b", "? {a: 1}\n: b", "{1.5: x}"] {
            #expect(yamlError(text)?.code == .nonStringKey, "\(text)")
        }
    }

    @Test("quoted or tagged numeric keys are strings")
    func stringKeys() throws {
        #expect(try yaml("'1': a\n!!str 2: b") == json(#"{"1":"a","2":"b"}"#))
    }

    @Test("merge key << is an ordinary string key under YAML 1.2")
    func mergeKeyIsPlain() throws {
        #expect(try yaml("base: &b {a: 1}\nderived:\n  <<: *b\n") == json(#"{"base":{"a":1},"derived":{"<<":{"a":1}}}"#))
    }
}

struct StructureTests {
    @Test("block and flow collections nest")
    func collections() throws {
        let text = """
        title: Hello
        tags: [a, b, {c: d}]
        items:
          - name: one
            n: 1
          - [x, y]
          -
        nested:
        - a
        - b
        """
        #expect(try yaml(text) == json(#"""
        {"title":"Hello","tags":["a","b",{"c":"d"}],"items":[{"name":"one","n":1},["x","y"],null],"nested":["a","b"]}
        """#))
    }

    @Test("literal and folded block scalars with chomping and indentation indicators")
    func blockScalars() throws {
        let text = "a: |\n  one\n  two\n\nb: >\n  one\n  two\n\n  three\nc: |-\n  x\n\nd: |+\n  x\n\ne: |2\n    indented\nf: >-\n  folded\n    more\n  back\n"
        #expect(try yaml(text) == json(#"""
        {"a":"one\ntwo\n","b":"one two\nthree\n","c":"x","d":"x\n\n","e":"  indented\n","f":"folded\n  more\nback"}
        """#))
    }

    @Test("single- and double-quoted scalars with escapes and line folding")
    func quoted() throws {
        #expect(try yaml(#"['it''s', "tab\tnew\nline \u00e9 \x41 \U0001F600 \/ \\", "a\n  b\n\n  c", "x\\n  y"]"#
            .replacingOccurrences(of: "\\n  b", with: "\n  b").replacingOccurrences(of: "\\n\\n  c", with: "\n\n  c")
            .replacingOccurrences(of: "x\\\\n  y", with: "x\\\n  y")) ==
            json(#"["it's","tab\tnew\nline é A 😀 / \\","a b\nc","xy"]"#))
    }

    @Test("comments are ignored")
    func comments() throws {
        #expect(try yaml("# head\na: 1 # trailing\n# between\nb: 'x # not a comment'\nc: x#y\n") ==
                json(#"{"a":1,"b":"x # not a comment","c":"x#y"}"#))
    }

    @Test("multi-line plain scalars fold")
    func plainFolding() throws {
        #expect(try yaml("a: one\n  two\n\n  three\n") == json(#"{"a":"one two\nthree"}"#))
    }

    @Test("anchors and aliases expand to equal values")
    func aliases() throws {
        #expect(try yaml("a: &x [1, {b: 2}]\nc: *x\nd: &y hi\ne: *y") ==
                json(#"{"a":[1,{"b":2}],"c":[1,{"b":2}],"d":"hi","e":"hi"}"#))
    }

    @Test("an anchor may be redefined; aliases use the latest definition")
    func anchorRedefinition() throws {
        #expect(try yaml("[&a 1, *a, &a 2, *a]") == json("[1,1,2,2]"))
    }

    @Test("a UTF-8 byte order mark at the start is skipped")
    func byteOrderMark() throws {
        #expect(try YAMLParser().parse([0xEF, 0xBB, 0xBF] + Array("a: 1".utf8)) == json(#"{"a":1}"#))
    }

    @Test("CRLF line breaks are normalized")
    func crlf() throws {
        #expect(try yaml("a: |\r\n  x\r\n  y\r\nb: 1\r\n") == json(#"{"a":"x\ny\n","b":1}"#))
    }
}

struct StreamTests {
    @Test("multi-document streams yield one value per document in order")
    func stream() throws {
        let documents = try YAMLParser().parseStream("---\na: 1\n---\n- 2\n...\n--- 3\n---\n")
        #expect(documents == [try json(#"{"a":1}"#), try json("[2]"), try json("3"), .null])
    }

    @Test("directives are accepted before an explicit document")
    func directives() throws {
        #expect(try YAMLParser().parseStream("%YAML 1.2\n%TAG !x! tag:yaml.org,2002:\n---\n!x!int '5'\n") == [try json("5")])
    }

    @Test("an empty stream has no documents; parse returns null for it")
    func emptyStream() throws {
        #expect(try YAMLParser().parseStream("# only a comment\n").isEmpty)
        #expect(try YAMLParser().parseStream("").isEmpty)
        #expect(try yaml("") == .null)
        #expect(try yaml("---\n") == .null)
    }

    @Test("parse rejects a stream with more than one document")
    func multipleDocuments() throws {
        let error = try #require({ () -> YAMLError? in
            do { _ = try yaml("a: 1\n---\nb: 2\n"); return nil } catch { return error as? YAMLError }
        }())
        #expect(error.code == .multipleDocuments)
        #expect(error.line == 3)
    }
}

struct SyntaxErrorTests {
    @Test("syntax errors carry 1-based line and column")
    func positions() throws {
        let error = try #require(yamlError("a: 1\nb: [1, 2\nc: 3\n"))
        #expect(error.code == .syntax)
        #expect(error.line >= 2)
        let tab = try #require(yamlError("a:\n\tb: 1\n"))
        #expect(tab.code == .syntax)
        #expect(tab.line == 2)
        let bad = try #require(yamlError("key: \"unterminated\n"))
        #expect(bad.code == .syntax)
        #expect(bad.description.hasPrefix("\(bad.line):\(bad.column): "))
    }

    @Test("malformed documents are syntax errors")
    func malformed() {
        for text in ["a: b: c", "- a\nb: c", "[a, b", "{a: 1", "a:\n  - b\n c: d", "\"a\" \"b\"", "key: \"x\"#c", "&a &b x", "*", "%YAML 2.0\n---\na", "--- a\n... b", "a: 'x\n---\ny'", "\"\\q\"", "|0\n x", "!<tag:yaml.org,2002:str x"] {
            #expect(yamlError(text)?.code == .syntax, "\(text)")
        }
    }

    @Test("invalid UTF-8 and non-printable characters are encoding errors")
    func encoding() throws {
        do {
            _ = try YAMLParser().parse([0x61, 0x3A, 0x20, 0xFF])
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .invalidEncoding)
        }
        let control = try #require(yamlError("a: b\u{01}"))
        #expect(control.code == .invalidEncoding)
        #expect(control.line == 1 && control.column == 5)
    }

    @Test("an alias without a preceding anchor is an error")
    func undefinedAlias() {
        #expect(yamlError("a: *nope")?.code == .undefinedAlias)
        #expect(yamlError("a: *b\nb: &b 1")?.code == .undefinedAlias)
        #expect(yamlError("&a [*a]")?.code == .undefinedAlias)
        #expect(yamlError("--- &a 1\n--- *a")?.code == .undefinedAlias)
    }
}

struct LimitTests {
    @Test("input larger than maxInputBytes fails")
    func inputBytes() {
        #expect(yamlError("a: 12345", limits: YAMLLimits(maxInputBytes: 4))?.code == .inputTooLarge)
    }

    @Test("nesting deeper than maxDepth fails, in block and flow style")
    func depth() throws {
        let limits = YAMLLimits(maxDepth: 3)
        #expect(try yaml("[[[1]]]", limits: limits) == json("[[[1]]]"))
        #expect(yamlError("[[[[1]]]]", limits: limits)?.code == .depthLimitExceeded)
        #expect(yamlError("a:\n b:\n  c:\n   d: 1\n", limits: limits)?.code == .depthLimitExceeded)
        #expect(yamlError(String(repeating: "[", count: 100_000))?.code == .depthLimitExceeded)
    }

    @Test("nesting at the default maxDepth of 128 parses on an ordinary task thread, in block and flow style")
    func deepNestingDoesNotUseTheCallStack() async throws {
        let flow = String(repeating: "[", count: 128) + "1" + String(repeating: "]", count: 128)
        var block = ""
        for level in 0..<127 { block += String(repeating: " ", count: level) + "k:\n" }
        block += String(repeating: " ", count: 127) + "- x\n"
        let results = await Task.detached { () -> [Bool] in
            [(try? YAMLParser().parse(flow)) != nil, (try? YAMLParser().parse(block)) != nil,
             (try? YAMLParser().parse("[" + flow + "]")) == nil]
        }.value
        #expect(results == [true, true, true])
    }

    @Test("aliases cannot exceed maxDepth by expansion")
    func depthThroughAliases() {
        let limits = YAMLLimits(maxDepth: 3)
        #expect(yamlError("a: &x [[1]]\nb: [[*x]]", limits: limits)?.code == .depthLimitExceeded)
    }

    @Test("more nodes than maxNodes fails, counted across documents")
    func nodes() {
        let limits = YAMLLimits(maxNodes: 5)
        #expect(yamlError("[1, 2, 3, 4, 5, 6]", limits: limits)?.code == .nodeLimitExceeded)
        #expect(yamlError("--- [1, 2]\n--- [3, 4]\n", limits: limits)?.code == .nodeLimitExceeded)
    }

    @Test("billion laughs is stopped by maxAliasExpansion")
    func billionLaughs() throws {
        var text = "a0: &a0 [lol, lol, lol, lol, lol, lol, lol, lol, lol, lol]\n"
        for i in 1...9 {
            let refs = Array(repeating: "*a\(i - 1)", count: 10).joined(separator: ", ")
            text += "a\(i): &a\(i) [\(refs)]\n"
        }
        let error = try #require(yamlError(text))
        #expect(error.code == .aliasExpansionLimitExceeded)
        #expect(yamlError("a: &a [1, 2, 3]\nb: [*a, *a]", limits: YAMLLimits(maxAliasExpansion: 7))?.code == .aliasExpansionLimitExceeded)
        #expect(throws: Never.self) { try yaml("a: &a [1, 2, 3]\nb: [*a, *a]", limits: YAMLLimits(maxAliasExpansion: 8)) }
    }

    @Test("a cancelled task stops parsing")
    func cancellation() async {
        let task = Task { () -> YAMLError.Code? in
            withUnsafeCurrentTask { $0?.cancel() }
            return yamlError("a: 1")?.code
        }
        #expect(await task.value == .cancelled)
    }
}
