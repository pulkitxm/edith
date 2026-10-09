// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdithHost", targets: ["EdithHost"]),
        .executable(name: "HostLifecycleHarness", targets: ["HostLifecycleHarness"]),
        .executable(name: "HostCommandHarness", targets: ["HostCommandHarness"]),
    ],
    dependencies: [
        .package(path: "../ExtensionMarketplace"),
        .package(path: "../ExtensionSupport"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
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
                "EdithHostCore", .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-no_exported_symbols", "-Xlinker", "-dead_strip"],
                    .when(configuration: .release))
            ]),
        .executableTarget(
            name: "HostLifecycleHarness", dependencies: ["EdithHostCore"],
            path: "Tests/LifecycleHarness"),
        .executableTarget(
            name: "HostCommandHarness", dependencies: ["EdithHostCore"],
            path: "Tests/CommandHarness"),
        .testTarget(
            name: "EdithHostCoreTests", dependencies: ["EdithHostCore"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "EdithHostUITests", dependencies: ["EdithHost"]),
    ]
)
