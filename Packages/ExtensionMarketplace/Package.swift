// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtensionMarketplace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExtensionMarketplace", type: .static, targets: ["ExtensionMarketplace"]),
        .executable(name: "MarketplaceHarness", targets: ["MarketplaceHarness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
        .package(path: "../ExtensionSupport"),
    ],
    targets: [
        .target(
            name: "ExtensionMarketplace",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "EdithExtensionKit", package: "ExtensionSupport"),
            ]),
        .executableTarget(
            name: "MarketplaceHarness", dependencies: ["ExtensionMarketplace"],
            path: "Tests/Harness",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        .testTarget(name: "ExtensionMarketplaceTests", dependencies: ["ExtensionMarketplace"]),
    ]
)
