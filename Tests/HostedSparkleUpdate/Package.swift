// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HostedSparkleUpdate",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SparkleFixtureContract", targets: ["SparkleFixtureContract"])],
    targets: [
        .target(name: "SparkleFixtureContract"),
        .testTarget(name: "SparkleFixtureContractTests", dependencies: ["SparkleFixtureContract"]),
    ])
