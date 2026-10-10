// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SystemStatsExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ExtensionSupport", path: "../../Packages/ExtensionSupport"),
        .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "SystemStatsExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemStatsExtensionTests",
            dependencies: [
                "SystemStatsExtension",
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
            ],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5), .define("SYSTEM_STATS_NATIVE_RUNTIME")]),
    ])
