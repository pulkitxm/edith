// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HostedManagedNativeProbe",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProbeContract", targets: ["ProbeContract"])],
    targets: [
        .target(name: "ProbeContract"),
        .testTarget(name: "ProbeContractTests", dependencies: ["ProbeContract"]),
    ]
)
