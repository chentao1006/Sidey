// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Sidey",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Sidey", targets: ["Sidey"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/MarkdownUI", from: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "Sidey",
            dependencies: [
                .product(name: "MarkdownUI", package: "MarkdownUI")
            ],
            path: "Sources/Sidey",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
