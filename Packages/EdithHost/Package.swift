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
            name: "HostLifecycleHarness", dependencies: ["EdithHostCore"],
            path: "Tests/LifecycleHarness"),
        .executableTarget(
            name: "HostCommandHarness", dependencies: ["EdithHostCore"],
            path: "Tests/CommandHarness"),
        .executableTarget(
            name: "HostNativeTaskHarness", dependencies: ["EdithHostCore"],
            path: "Tests/NativeTaskHarness"),
        .testTarget(
            name: "EdithHostCoreTests", dependencies: ["EdithHostCore"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "EdithHostUITests", dependencies: ["EdithHost"]),
        .testTarget(name: "HostLifecycleHarnessTests", dependencies: ["HostLifecycleHarness"]),
    ]
)
