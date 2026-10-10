// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WorkerFixtureSupport", platforms: [.macOS(.v14)],
    products: [.library(name: "WorkerFixtureSupport", targets: ["WorkerFixtureSupport"])],
    targets: [
        .target(
            name: "WorkerFixtureSupport", path: ".", exclude: ["Tests", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "WorkerFixtureSupportTests", dependencies: ["WorkerFixtureSupport"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
