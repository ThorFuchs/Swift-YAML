# Frontmatter

Split and parse YAML frontmatter at the start of a Markdown file.

## Overview

A file has frontmatter only when its first line is `---`. An optional UTF-8 byte order
mark before it is allowed. The frontmatter ends at the next line that is `---`. Fence
lines may have trailing spaces or tabs, and line endings may be LF or CRLF.

```markdown
---
title: Hello
tags: [a, b]
---
# Heading
```

``YAMLParser/parseFrontmatter(_:)`` splits and parses in one step:

```swift
let file = Array(markdown.utf8)
if let front = try YAMLParser().parseFrontmatter(file) {
    front.data           // {"title": "Hello", "tags": ["a", "b"]}
    front.body           // the bytes of "# Heading\n"
    front.bodyStartLine  // 5
} else {
    // No frontmatter; the whole file is body.
}
```

- A file without an opening fence returns `nil`.
- An empty frontmatter block parses to `.null`.
- An opening fence with no closing fence is
  ``YAMLError/Code-swift.enum/unterminatedFrontmatter``. The parser never guesses where
  the body starts.
- Error positions from ``YAMLParser/parseFrontmatter(_:)`` refer to lines of the whole
  file.

To only split the file, without parsing the YAML, use ``YAMLFrontmatter/split(_:)``.
