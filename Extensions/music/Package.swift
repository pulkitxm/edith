// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicExtension",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "MusicExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests", "Runtime.swift", "Native", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MusicExtensionTests", dependencies: ["MusicExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
