// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdithHost", targets: ["EdithHost"]),
        .executable(name: "HostNativeTaskHarness", targets: ["HostNativeTaskHarness"]),
    ],
    dependencies: [
        .package(path: "../ExtensionMarketplace"),
        .package(path: "../ExtensionSupport"),
        .package(path: "../../Extensions/fixtureSupport"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "HostBootstrap"),
        .target(
            name: "EdithHostCore",
            dependencies: [
                .product(name: "ExtensionMarketplace", package: "ExtensionMarketplace"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            resources: [.process("Resources")]),
        .executableTarget(
            name: "EdithHost",
            dependencies: [
                "HostBootstrap", "EdithHostCore", .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            resources: [.copy("Resources/MarketplaceArtwork.lzma")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker",
                    "-application_extension",
                ]),
                .unsafeFlags(
                    ["-Xlinker", "-no_exported_symbols", "-Xlinker", "-dead_strip"],
                    .when(configuration: .release)),
            ]),
        .executableTarget(
            name: "HostNativeTaskHarness", dependencies: ["EdithHostCore"],
            path: "Tests/NativeTaskHarness"),
        .target(
            name: "HostAccessibilityFixtureSupport", path: "Tests/HostAccessibilityFixtureSupport"),
        .target(
            name: "HostWorkerFixtureSupport", dependencies: ["EdithHostCore"],
            path: "Tests/HostWorkerFixtureSupport"),
        .testTarget(
            name: "EdithHostCoreTests",
            dependencies: [
                "EdithHostCore", "HostAccessibilityFixtureSupport", "HostWorkerFixtureSupport",
            ],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "EdithHostUITests",
            dependencies: [
                "EdithHost", "HostAccessibilityFixtureSupport", "HostWorkerFixtureSupport",
            ]),
        .testTarget(
            name: "HostCommandFixtureTests",
            dependencies: [.product(name: "EdithExtensionSupport", package: "ExtensionSupport")],
            path: "Tests/CommandFixture"),
    ]
)
