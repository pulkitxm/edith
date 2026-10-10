// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CleanerExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "CleanerExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CleanerExtensionTests", dependencies: ["CleanerExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
