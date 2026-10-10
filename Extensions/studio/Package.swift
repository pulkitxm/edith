// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StudioExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "NativeRuntime"),
    ],
    targets: [
        .target(
            name: "StudioExtension",
            dependencies: [
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithStudio", package: "NativeRuntime"),
            ],
            path: ".",
            exclude: ["Tests", "NativeRuntime", "Makefile", "test.mjs"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "StudioExtensionTests",
            dependencies: [
                "StudioExtension", .product(name: "EdithStudio", package: "NativeRuntime"),
            ],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
