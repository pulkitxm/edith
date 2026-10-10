// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HostedOriginalShell",
    platforms: [.macOS(.v14)],
    products: [.library(name: "JourneyContract", targets: ["JourneyContract"])],
    targets: [
        .target(name: "JourneyContract"),
        .testTarget(name: "JourneyContractTests", dependencies: ["JourneyContract"]),
    ])
