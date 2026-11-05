// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BlitzTreeExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "BlitzTreeExtension",
            dependencies: [
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BlitzTreeExtensionTests",
            dependencies: [
                "BlitzTreeExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
