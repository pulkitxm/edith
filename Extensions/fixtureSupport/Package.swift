// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WorkerFixtureSupport", platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkerFixtureSupport", targets: ["WorkerFixtureSupport"]),
        .library(name: "WorkerFixtureTestSupport", targets: ["WorkerFixtureTestSupport"]),
    ],
    targets: [
        .target(
            name: "WorkerFixtureTestSupport", dependencies: ["WorkerFixtureSupport"],
            path: "Tests/Support", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "WorkerFixtureSupport", path: ".",
            exclude: ["Tests", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "WorkerFixtureSupportTests", dependencies: ["WorkerFixtureSupport"],
            path: "Tests", exclude: ["Support"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
