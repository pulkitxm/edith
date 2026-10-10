// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CodeStatsExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "CodeStatsExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CodeStatsExtensionTests", dependencies: ["CodeStatsExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
