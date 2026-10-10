// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LidAwakeExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: "../../Packages/ExtensionSupport")
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
