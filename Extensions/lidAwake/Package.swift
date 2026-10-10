// swift-tools-version:6.0
import PackageDescription
import Foundation

let package = Package(
    name: "LidAwakeExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: ProcessInfo.processInfo.environment["EDITH_EXTENSION_TEST_SDK"]
                ?? "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "LidAwakeExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests", "Privileged/LidAwakePrivilegedRuntime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LidAwakeExtensionTests", dependencies: ["LidAwakeExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
