// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HomeClaw",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "homeclaw", targets: ["homeclaw"]),
        .executable(name: "homeclaw-cli", targets: ["homeclaw-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "homeclaw",
            exclude: ["MCP/_disabled", "Shared/_disabled"]
        ),
        .executableTarget(
            name: "homeclaw-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Commands/_disabled"]
        ),
    ]
)
