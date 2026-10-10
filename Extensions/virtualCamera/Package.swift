// swift-tools-version:6.0
import PackageDescription
import Foundation

let package = Package(
    name: "VirtualCameraExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: ProcessInfo.processInfo.environment["EDITH_EXTENSION_TEST_SDK"]
                ?? "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "VirtualCameraExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport")
            ], path: ".", exclude: ["Tests", "Provider", "Carrier", "Privileged", "NativeRuntime"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "VirtualCameraExtensionTests", dependencies: ["VirtualCameraExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
