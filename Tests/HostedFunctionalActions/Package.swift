// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HostedFunctionalActions",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FunctionalActionContract", targets: ["FunctionalActionContract"])],
    dependencies: [.package(path: "../../Extensions/fixtureSupport")],
    targets: [
        .target(
            name: "FunctionalActionContract",
            dependencies: [.product(name: "WorkerFixtureSupport", package: "fixtureSupport")]),
        .testTarget(
            name: "FunctionalActionContractTests", dependencies: ["FunctionalActionContract"]),
    ]
)
