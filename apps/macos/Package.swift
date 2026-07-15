// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Edith",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "EdithKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Edith",
            dependencies: ["EdithKit"],
            resources: [.copy("Resources/appicon.png")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EdithHelper",
            dependencies: ["EdithKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdithTests",
            dependencies: ["Edith", "EdithKit", "EdithHelper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
