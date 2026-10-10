// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalExtension",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport"), .package(path: "Native")],
    targets: [
        .target(
            name: "TerminalExtension",
            dependencies: [
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "GhosttyTerminal", package: "Native"),
            ],
            path: ".", exclude: ["Tests", "Native"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "TerminalExtensionTests", dependencies: ["TerminalExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
