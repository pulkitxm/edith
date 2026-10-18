// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LaTeXExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "LaTeXExtension",
            dependencies: [
                .product(name: "EdithExtensionArchive", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LaTeXExtensionTests", dependencies: ["LaTeXExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
