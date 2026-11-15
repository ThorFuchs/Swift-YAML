// SPDX-License-Identifier: Apache-2.0
import JSON

/// Splits YAML frontmatter from the start of a Markdown (or other text) file.
///
/// Frontmatter exists only when the very first line (after an optional UTF-8 byte order mark)
/// is `---`. It ends at the next line that is `---`. Trailing spaces or tabs on fence lines are
/// allowed; line endings may be LF or CRLF.
public struct YAMLFrontmatter: Sendable, Equatable {
    /// The bytes between the fences, excluding both fence lines.
    public let yaml: [UInt8]
    /// The 1-based line number of the first YAML line in the original file.
    public let yamlStartLine: Int
    /// Everything after the closing fence line.
    public let body: [UInt8]
    /// The 1-based line number of the first body line in the original file.
    public let bodyStartLine: Int

    /// Splits `bytes`, or returns nil when the file does not start with a `---` line.
    ///
    /// - Throws: `YAMLError.Code.unterminatedFrontmatter` when the opening fence has no closing fence.
    public static func split(_ bytes: [UInt8]) throws(YAMLError) -> YAMLFrontmatter? {
        var start = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        guard let afterOpening = fenceLineEnd(bytes, from: start) else { return nil }
        var lineStart = afterOpening
        var line = 2
        while lineStart < bytes.count {
            if let afterClosing = fenceLineEnd(bytes, from: lineStart) {
                return YAMLFrontmatter(yaml: Array(bytes[afterOpening..<lineStart]), yamlStartLine: 2,
                                       body: Array(bytes[afterClosing...]), bodyStartLine: line + 1)
            }
            guard let newline = bytes[lineStart...].firstIndex(of: 0x0A) else { break }
            lineStart = newline + 1
            line += 1
        }
        throw YAMLError(.unterminatedFrontmatter, "frontmatter opened with '---' is not closed by a '---' line",
                        line: 1, column: 1)
    }

    /// If a `---` fence line starts at `index`, returns the index just after its line break (or the end).
    private static func fenceLineEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        guard index + 3 <= bytes.count, bytes[index] == 0x2D, bytes[index + 1] == 0x2D, bytes[index + 2] == 0x2D else {
            return nil
        }
        var i = index + 3
        while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09) { i += 1 }
        if i == bytes.count { return i }
        if bytes[i] == 0x0A { return i + 1 }
        if bytes[i] == 0x0D && i + 1 < bytes.count && bytes[i + 1] == 0x0A { return i + 2 }
        return nil
    }
}

/// Frontmatter data parsed from a file, plus the remaining body.
public struct ParsedFrontmatter: Sendable, Equatable {
    /// The YAML document between the fences; `.null` when it is empty.
    public let data: JSON
    /// Everything after the closing fence line.
    public let body: [UInt8]
    /// The 1-based line number of the first body line in the original file.
    public let bodyStartLine: Int
}

extension YAMLParser {
    /// Splits and parses frontmatter, or returns nil when the file has none.
    ///
    /// Error positions refer to lines of the whole file, not of the frontmatter block.
    public func parseFrontmatter(_ bytes: [UInt8]) throws(YAMLError) -> ParsedFrontmatter? {
        guard let split = try YAMLFrontmatter.split(bytes) else { return nil }
        let data: JSON
        do {
            data = try parse(split.yaml)
        } catch {
            throw error.shifted(byLines: split.yamlStartLine - 1)
        }
        return ParsedFrontmatter(data: data, body: split.body, bodyStartLine: split.bodyStartLine)
    }
}
