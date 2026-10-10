// swift-tools-version:6.0
import PackageDescription
import Foundation

let package = Package(
    name: "SystemExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: ProcessInfo.processInfo.environment["EDITH_EXTENSION_TEST_SDK"]
                ?? "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "SystemExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemExtensionTests", dependencies: ["SystemExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
