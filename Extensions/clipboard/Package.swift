// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipboardExtension",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "ClipboardExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ], path: ".", exclude: ["Tests", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ClipboardExtensionTests", dependencies: ["ClipboardExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
