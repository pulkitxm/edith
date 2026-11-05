// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VirtualCameraExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "VirtualCameraExtension",
            dependencies: [
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ], path: ".", exclude: ["Tests", "Carrier", "Privileged"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "VirtualCameraExtensionTests",
            dependencies: [
                "VirtualCameraExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
