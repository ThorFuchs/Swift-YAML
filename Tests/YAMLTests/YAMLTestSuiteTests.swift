// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import Testing
@testable import YAML

/// Runs the vendored yaml-test-suite (data-2022-01-17) against the parser.
///
/// Outcomes per case:
/// - `pass`: an error case throws, or a valid case matches `in.json` (or parses, when there is no `in.json`).
/// - `policy`: a valid case is rejected on purpose because JSON cannot represent it
///   (custom tags, non-string keys, `.inf`/`.nan`). See README "Deliberate differences".
/// - `fail`: anything else. These must be exactly `knownFailures`, which the README lists.
struct YAMLTestSuiteTests {
    enum Outcome: Equatable { case pass, policy(YAMLError.Code), fail(String) }

    static let policyCodes: Set<YAMLError.Code> = [.unsupportedTag, .nonStringKey, .nonFiniteNumber, .invalidTaggedValue]

    /// Cases the parser does not handle correctly yet. Keep in sync with README.md.
    static let knownFailures: Set<String> = []

    static func suiteDirectory() throws -> URL {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return fixtures.appendingPathComponent("yaml-test-suite")
    }

    static func caseIDs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: suiteDirectory().path)
            .filter { $0 != "LICENSE" }
            .sorted()
    }

    static func run(_ id: String) throws -> Outcome {
        let dir = try suiteDirectory().appendingPathComponent(id)
        let yaml = try [UInt8](Data(contentsOf: dir.appendingPathComponent("in.yaml")))
        let expectsError = FileManager.default.fileExists(atPath: dir.appendingPathComponent("error").path)
        let jsonURL = dir.appendingPathComponent("in.json")
        let expected: [JSON]? = FileManager.default.fileExists(atPath: jsonURL.path)
            ? try splitJSONStream(try [UInt8](Data(contentsOf: jsonURL))) : nil
        let actual: [JSON]
        do {
            actual = try YAMLParser().parseStream(yaml)
        } catch {
            if expectsError {
                if ProcessInfo.processInfo.environment["YAML_SUITE_VERBOSE"] != nil { print("rejected \(id) \(error.code)") }
                return .pass
            }
            if policyCodes.contains(error.code) { return .policy(error.code) }
            return .fail("unexpected error \(error.code) \(error)")
        }
        if expectsError { return .fail("expected an error, parsed \(actual.count) document(s)") }
        if let expected, expected != actual {
            return .fail("expected \(expected), got \(actual)")
        }
        return .pass
    }

    /// Splits whitespace-separated JSON texts (in.json may hold one value per document).
    static func splitJSONStream(_ bytes: [UInt8]) throws -> [JSON] {
        var values: [JSON] = []
        var i = 0
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
        while i < bytes.count {
            while i < bytes.count && isSpace(bytes[i]) { i += 1 }
            guard i < bytes.count else { break }
            let start = i
            var depth = 0
            var inString = false
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                if inString {
                    if b == 0x5C { i += 1 } else if b == 0x22 { inString = false; if depth == 0 { break } }
                } else if b == 0x22 {
                    inString = true
                } else if b == 0x7B || b == 0x5B {
                    depth += 1
                } else if b == 0x7D || b == 0x5D {
                    depth -= 1
                    if depth == 0 { break }
                } else if depth == 0 && i < bytes.count && isSpace(bytes[i]) {
                    break
                }
            }
            values.append(try JSON.parse(Array(bytes[start..<i])))
        }
        return values
    }

    @Test("yaml-test-suite: every case passes, is a deliberate policy rejection, or is a listed known failure")
    func suite() throws {
        var failures: [String: String] = [:]
        var passes = 0, policies = 0
        for id in try Self.caseIDs() {
            switch try Self.run(id) {
            case .pass: passes += 1
            case .policy(let code):
                policies += 1
                if ProcessInfo.processInfo.environment["YAML_SUITE_VERBOSE"] != nil { print("policy \(id) \(code)") }
            case .fail(let reason): failures[id] = reason
            }
        }
        let unexpected = failures.filter { !Self.knownFailures.contains($0.key) }
        let fixed = Self.knownFailures.subtracting(failures.keys)
        print("yaml-test-suite: \(passes) pass, \(policies) policy, \(failures.count) fail")
        for (id, reason) in unexpected.sorted(by: { $0.key < $1.key }) {
            Issue.record("\(id): \(reason)")
        }
        #expect(fixed.isEmpty, "now passing, remove from knownFailures: \(fixed.sorted())")
    }
}
