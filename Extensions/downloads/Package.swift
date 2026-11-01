// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DownloadsExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "DownloadsExtension",
            dependencies: [
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DownloadsExtensionTests", dependencies: ["DownloadsExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
