// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TimeLapseExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "TimeLapseExtension",
            dependencies: [
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "TimeLapseExtensionTests",
            dependencies: [
                "TimeLapseExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
