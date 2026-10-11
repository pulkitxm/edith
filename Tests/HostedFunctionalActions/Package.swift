// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HostedFunctionalActions",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FunctionalActionContract", targets: ["FunctionalActionContract"])],
    targets: [
        .target(name: "FunctionalActionContract"),
        .testTarget(
            name: "FunctionalActionContractTests", dependencies: ["FunctionalActionContract"]),
    ]
)
