// SPDX-License-Identifier: Apache-2.0
import Testing
import YAML

/// One minimal reproducer per error code. Adding a `YAMLError.Code` case without a
/// reproducer here fails the build of the test plan, not just a review checklist.
struct ErrorCodeCoverageTests {
    static func reproduce(_ code: YAMLError.Code) async -> YAMLError? {
        func stream(_ text: String, _ limits: YAMLLimits = .default) -> YAMLError? {
            do { _ = try YAMLParser(limits: limits).parseStream(text); return nil } catch { return error }
        }
        switch code {
        case .invalidEncoding:
            do { _ = try YAMLParser().parse([0xC3, 0x28]); return nil } catch { return error }
        case .syntax: return stream("[a, b")
        case .duplicateKey: return stream("a: 1\na: 2")
        case .nonStringKey: return stream("1: one")
        case .unsupportedTag: return stream("!custom value")
        case .invalidTaggedValue: return stream("!!int twelve")
        case .nonFiniteNumber: return stream(".inf")
        case .numberOutOfRange: return stream("1e9999999999")
        case .undefinedAlias: return stream("*missing")
        case .multipleDocuments:
            do { _ = try YAMLParser().parse("--- 1\n--- 2\n"); return nil } catch { return error }
        case .unterminatedFrontmatter:
            do { _ = try YAMLFrontmatter.split(Array("---\na: 1\n".utf8)); return nil } catch { return error }
        case .inputTooLarge: return stream("a: 1", YAMLLimits(maxInputBytes: 1))
        case .depthLimitExceeded: return stream("[[1]]", YAMLLimits(maxDepth: 1))
        case .nodeLimitExceeded: return stream("[1, 2]", YAMLLimits(maxNodes: 2))
        case .aliasExpansionLimitExceeded: return stream("a: &a [1]\nb: *a", YAMLLimits(maxAliasExpansion: 1))
        case .cancelled:
            return await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return stream("a: 1")
            }.value
        }
    }

    @Test("every error code has a minimal input that produces exactly that code", arguments: YAMLError.Code.allCases)
    func everyCodeIsReproducible(_ code: YAMLError.Code) async throws {
        let error = try #require(await Self.reproduce(code), "no error for \(code)")
        #expect(error.code == code)
        #expect(error.line >= 1 && error.column >= 1)
        #expect(!error.message.isEmpty)
        #expect(!error.message.contains("/Users/") && !error.message.contains("/home/"))
    }
}
