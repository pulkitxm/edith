// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostedManagedApprovalContract",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HostedManagedApprovalContract", path: ".",
            exclude: ["Tests", "HostedManagedApprovalHost.swift"],
            sources: ["HostedManagedApprovalContract.swift"]),
        .testTarget(
            name: "HostedManagedApprovalContractTests",
            dependencies: ["HostedManagedApprovalContract"], path: "Tests"),
    ])
