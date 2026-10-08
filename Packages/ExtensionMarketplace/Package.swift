// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtensionMarketplace",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ExtensionMarketplace", targets: ["ExtensionMarketplace"])],
    targets: [
        .target(name: "ExtensionMarketplace"),
        .testTarget(name: "ExtensionMarketplaceTests", dependencies: ["ExtensionMarketplace"]),
    ]
)
