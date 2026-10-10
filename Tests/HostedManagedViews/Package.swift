// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ManagedViewContract",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ManagedViewContract", targets: ["ManagedViewContract"])],
    targets: [
        .target(name: "ManagedViewContract"),
        .testTarget(name: "ManagedViewContractTests", dependencies: ["ManagedViewContract"]),
    ])
