// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchShelfExtension",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "NotchShelfExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "NotchShelfExtensionTests", dependencies: ["NotchShelfExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
