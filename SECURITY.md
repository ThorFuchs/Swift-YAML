# Security Policy

Swift-YAML is designed to parse untrusted input. It enforces explicit limits on input
size, nesting depth, node count and alias expansion, and it does not recurse over
nesting. A crash, hang, stack overflow, unbounded memory use or a limit that can be
bypassed is a security issue.

## Supported versions

Security fixes go to the latest release.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/ThorFuchs/Swift-YAML/security/advisories/new).
Do not open a public issue.

Include the input that triggers the problem, the limits used, and the platform and Swift
version. You can expect an initial response within a week. Fixes are released as patch
versions, with credit unless you prefer otherwise.
