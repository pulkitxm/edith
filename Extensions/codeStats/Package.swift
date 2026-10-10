// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CodeStatsExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "CodeStatsExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CodeStatsExtensionTests",
            dependencies: [
                "CodeStatsExtension",
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
            ], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
