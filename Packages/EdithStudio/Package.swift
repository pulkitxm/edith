// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EdithStudio", targets: ["EdithStudio"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")
    ],
    targets: [
        .target(
            name: "EdithStudio",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdithStudioTests",
            dependencies: ["EdithStudio"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
