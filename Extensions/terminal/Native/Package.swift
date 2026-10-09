// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhosttyTerminal", type: .dynamic, targets: ["GhosttyTerminal"])
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit"],
            resources: [.copy("Resources/Fonts"), .copy("../../vendor/GhosttyResources")],
            swiftSettings: [
                .swiftLanguageMode(.v5), .enableExperimentalFeature("CheckImplementationOnly"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"), .linkedFramework("Carbon"),
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"), .linkedFramework("CoreText"),
            ]),
        .testTarget(
            name: "GhosttyTerminalTests", dependencies: ["GhosttyTerminal", "GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
