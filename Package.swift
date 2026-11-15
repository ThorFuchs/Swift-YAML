// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Swift-YAML",
    // Floors match Swift Content Collections, the first consumer.
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "YAML", targets: ["YAML"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", exact: "1.9.0"),
    ],
    targets: [
        .target(
            name: "YAML",
            dependencies: [.product(name: "JSON", package: "Swift-JSON")]
        ),
        .testTarget(
            name: "YAMLTests",
            dependencies: ["YAML", .product(name: "JSON", package: "Swift-JSON")],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
