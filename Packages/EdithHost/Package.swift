// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdithHost", targets: ["EdithHost"]),
        .executable(name: "HostLifecycleHarness", targets: ["HostLifecycleHarness"]),
    ],
    dependencies: [.package(path: "../ExtensionMarketplace")],
    targets: [
        .target(
            name: "EdithHostCore",
            dependencies: [.product(name: "ExtensionMarketplace", package: "ExtensionMarketplace")],
            resources: [.process("Resources")]),
        .executableTarget(name: "EdithHost", dependencies: ["EdithHostCore"]),
        .executableTarget(
            name: "HostLifecycleHarness", dependencies: ["EdithHostCore"],
            path: "Tests/LifecycleHarness"),
        .testTarget(
            name: "EdithHostCoreTests", dependencies: ["EdithHostCore"],
            resources: [.copy("Fixtures")]),
    ]
)
