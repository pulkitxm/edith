// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "HerdrUI", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../terminal/Native"),
        .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "HerdrUI",
            dependencies: [
                .product(name: "EdithExtensionDocuments", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "GhosttyTerminal", package: "Native"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ], path: ".", exclude: ["Tests"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HerdrExtensionTests", dependencies: ["HerdrUI"], path: "Tests/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HerdrUITests",
            dependencies: [
                "HerdrUI", .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
            ], path: "Tests/UI",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
