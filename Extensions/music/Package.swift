// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "MusicExtension",
            dependencies: [
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ],
            path: ".",
            exclude: ["Tests", "Runtime.swift", "Native", "Package.swift", "UI"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "MusicEmbeddedUI",
            dependencies: [
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "UI", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MusicEmbeddedUITests",
            dependencies: [
                "MusicEmbeddedUI", "MusicExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "Tests/Embedded",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MusicExtensionTests",
            dependencies: [
                "MusicExtension", .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ], path: "Tests",
            exclude: ["Embedded"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
