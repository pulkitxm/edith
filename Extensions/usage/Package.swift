// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsageExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "UsageExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ], path: ".", exclude: ["Tests", "Package.swift", "Makefile"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "UsageExtensionTests",
            dependencies: [
                "UsageExtension",
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
            ], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
