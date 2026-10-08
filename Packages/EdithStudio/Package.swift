// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EdithStudio", targets: ["EdithStudio"])
    ],
    dependencies: [
        .package(path: "../ExtensionMarketplace")
    ],
    targets: [
        .target(
            name: "EdithStudio",
            dependencies: [.product(name: "ExtensionMarketplace", package: "ExtensionMarketplace")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdithStudioTests",
            dependencies: ["EdithStudio"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
