// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtensionMarketplace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExtensionMarketplace", type: .dynamic, targets: ["ExtensionMarketplace"]),
        .executable(name: "MarketplaceHarness", targets: ["MarketplaceHarness"]),
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")],
    targets: [
        .target(
            name: "ExtensionMarketplace",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .executableTarget(
            name: "MarketplaceHarness", dependencies: ["ExtensionMarketplace"],
            path: "Tests/Harness"),
        .testTarget(name: "ExtensionMarketplaceTests", dependencies: ["ExtensionMarketplace"]),
    ]
)
