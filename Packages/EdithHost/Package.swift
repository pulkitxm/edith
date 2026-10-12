// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdithHost", targets: ["EdithHost"]),
        .executable(name: "HostLifecycleHarness", targets: ["HostLifecycleHarness"]),
        .executable(name: "HostCommandHarness", targets: ["HostCommandHarness"]),
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
        .target(
            name: "WorkerLifecycleFixtureSupport", path: "Tests/LifecycleHarness",
            exclude: [
                "AgentActivityFixture.swift",
                "AudioMixerFixture.swift",
                "CalendarFixture.swift",
                "CameraFixture.swift",
                "CodeStatsFixture.swift",
                "CompanionFixture.swift",
                "DatabaseFixture.swift",
                "Harness.swift",
                "HerdrFixture.swift",
                "MachinesFixture.swift",
                "NotchFixture.swift",
                "QuinjetFixture.swift",
                "QuinjetLifecycleFixture.swift",
                "StudioFixture.swift",
                "SurfaceActionRejection.swift",
                "SystemFixture.swift",
                "TerminalLifecycleFixture.swift",
                "UsageFixture.swift",
                "UsageLauncherFixture.swift",
            ],
            sources: ["WorkerLifecycleFixture.swift"]),
        .executableTarget(
            name: "HostLifecycleHarness",
            dependencies: ["EdithHostCore", "WorkerLifecycleFixtureSupport"],
            path: "Tests/LifecycleHarness", exclude: ["WorkerLifecycleFixture.swift"]),
        .executableTarget(
            name: "HostCommandHarness",
            dependencies: ["EdithHostCore", "WorkerLifecycleFixtureSupport"],
            path: "Tests/CommandHarness"),
        .executableTarget(
            name: "HostNativeTaskHarness", dependencies: ["EdithHostCore"],
            path: "Tests/NativeTaskHarness"),
        .target(
            name: "HostAccessibilityFixtureSupport", path: "Tests/HostAccessibilityFixtureSupport"),
        .testTarget(
            name: "EdithHostCoreTests",
            dependencies: ["EdithHostCore", "HostAccessibilityFixtureSupport"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "EdithHostUITests",
            dependencies: [
                "EdithHost", "WorkerLifecycleFixtureSupport", "HostAccessibilityFixtureSupport",
            ]),
        .testTarget(
            name: "HostLifecycleHarnessTests",
            dependencies: ["HostLifecycleHarness", "WorkerLifecycleFixtureSupport"]),
        .testTarget(
            name: "HostCommandFixtureTests",
            dependencies: [.product(name: "EdithExtensionSupport", package: "ExtensionSupport")],
            path: "Tests/CommandFixture"),
    ]
)
