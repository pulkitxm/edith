// swift-tools-version:6.0
import PackageDescription
import Foundation

let package = Package(
    name: "CleanerExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: ProcessInfo.processInfo.environment["EDITH_EXTENSION_TEST_SDK"]
                ?? "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "CleanerExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CleanerExtensionTests", dependencies: ["CleanerExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
