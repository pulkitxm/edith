// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "HerdrUI", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../terminal/Native"),
    ],
    targets: [
        .target(
            name: "HerdrUI",
            dependencies: [
                .product(name: "EdithExtensionDocuments", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "GhosttyTerminal", package: "Native"),
            ], path: ".", exclude: ["Tests"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HerdrExtensionTests", dependencies: ["HerdrUI"], path: "Tests/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HerdrUITests", dependencies: ["HerdrUI"], path: "Tests/UI",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
