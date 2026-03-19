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
        .package(url: "https://github.com/gonzalezreal/MarkdownUI", from: "2.4.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Sidey",
            dependencies: [
                .product(name: "MarkdownUI", package: "MarkdownUI"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Sidey",
            exclude: [
                "Sidey.entitlements"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
