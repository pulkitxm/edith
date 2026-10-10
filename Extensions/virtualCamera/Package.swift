// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VirtualCameraExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "VirtualCameraExtension",
            dependencies: [
                .product(name: "EdithExtensionUI", package: "ExtensionSupport")
            ], path: ".", exclude: ["Tests", "Provider", "Carrier", "Privileged", "NativeRuntime"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "VirtualCameraExtensionTests", dependencies: ["VirtualCameraExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
