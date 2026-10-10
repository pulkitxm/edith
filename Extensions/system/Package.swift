// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SystemExtension",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "SystemExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemExtensionTests", dependencies: ["SystemExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
