// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HomeClaw",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "homeclaw-cli", targets: ["homeclaw-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/rensbreur/SwiftTUI.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "homeclaw-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
            ],
            exclude: ["Commands/_disabled"]
        ),
        .testTarget(
            name: "homeclaw-cliTests",
            dependencies: ["homeclaw-cli"]
        ),
    ]
)
