// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PresenterExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "PresenterExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PresenterExtensionTests",
            dependencies: [
                "PresenterExtension",
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
            ], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
