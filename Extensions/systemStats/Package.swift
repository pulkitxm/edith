// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SystemStatsExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "ExtensionSupport", path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "SystemStatsExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemStatsExtensionTests", dependencies: ["SystemStatsExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
