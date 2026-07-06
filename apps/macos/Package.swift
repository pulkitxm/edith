// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Edith",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "EdithKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Edith",
            dependencies: ["EdithKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EdithMenuBar",
            dependencies: ["EdithKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdithTests",
            dependencies: ["Edith", "EdithKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
