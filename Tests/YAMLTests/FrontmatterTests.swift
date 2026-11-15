// SPDX-License-Identifier: Apache-2.0
import JSON
import Testing
import YAML

struct FrontmatterTests {
    @Test("frontmatter splits into YAML, body and the body's first line")
    func split() throws {
        let file = Array("---\ntitle: Hi\ntags: [a]\n---\n# Heading\n\nText\n".utf8)
        let split = try #require(try YAMLFrontmatter.split(file))
        #expect(split.yaml == Array("title: Hi\ntags: [a]\n".utf8))
        #expect(split.yamlStartLine == 2)
        #expect(split.body == Array("# Heading\n\nText\n".utf8))
        #expect(split.bodyStartLine == 5)

        let parsed = try #require(try YAMLParser().parseFrontmatter(file))
        #expect(parsed.data == (try JSON.parse(#"{"title":"Hi","tags":["a"]}"#)))
        #expect(parsed.bodyStartLine == 5)
    }

    @Test("a file that does not start with a --- line has no frontmatter")
    func absent() throws {
        #expect(try YAMLFrontmatter.split(Array("# Title\n---\n".utf8)) == nil)
        #expect(try YAMLFrontmatter.split(Array(" ---\na: 1\n---\n".utf8)) == nil)
        #expect(try YAMLFrontmatter.split(Array("----\n".utf8)) == nil)
        #expect(try YAMLFrontmatter.split([]) == nil)
    }

    @Test("CRLF, BOM, trailing blanks on fences and a body-less file are accepted")
    func variants() throws {
        let crlf = try #require(try YAMLFrontmatter.split(Array("\u{FEFF}--- \r\na: 1\r\n---\t\r\nbody".utf8)))
        #expect(crlf.yaml == Array("a: 1\r\n".utf8))
        #expect(crlf.body == Array("body".utf8))
        #expect(crlf.bodyStartLine == 4)
        let noBody = try #require(try YAMLFrontmatter.split(Array("---\na: 1\n---".utf8)))
        #expect(noBody.body.isEmpty)
    }

    @Test("empty frontmatter parses to null")
    func empty() throws {
        let parsed = try #require(try YAMLParser().parseFrontmatter(Array("---\n---\nbody\n".utf8)))
        #expect(parsed.data == .null)
        #expect(parsed.bodyStartLine == 3)
    }

    @Test("an opening fence without a closing fence is an error")
    func unterminated() {
        #expect(throws: YAMLError.self) { try YAMLFrontmatter.split(Array("---\na: 1\n".utf8)) }
        do {
            _ = try YAMLFrontmatter.split(Array("---\na: 1\n...\n".utf8))
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .unterminatedFrontmatter)
            #expect(error.line == 1)
        }
    }

    @Test("frontmatter errors report lines of the whole file")
    func errorLines() {
        do {
            _ = try YAMLParser().parseFrontmatter(Array("---\na: 1\na: 2\n---\nbody\n".utf8))
            Issue.record("expected an error")
        } catch {
            #expect(error.code == .duplicateKey)
            #expect(error.line == 3)
        }
    }
}
