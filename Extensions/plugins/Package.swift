// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PluginsExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "PluginsExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionDocuments", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PluginsExtensionTests",
            dependencies: [
                "PluginsExtension",
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
            ],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
