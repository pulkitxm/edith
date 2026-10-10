// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BifrostExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "BifrostExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BifrostExtensionTests", dependencies: ["BifrostExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
