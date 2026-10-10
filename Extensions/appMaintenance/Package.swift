// swift-tools-version:6.0
import PackageDescription
import Foundation

let package = Package(
    name: "AppMaintenanceExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: ProcessInfo.processInfo.environment["EDITH_EXTENSION_TEST_SDK"]
                ?? "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "AppMaintenanceExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AppMaintenanceExtensionTests", dependencies: ["AppMaintenanceExtension"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
