// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AudioMixerExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "AudioMixerExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport")
            ], path: ".", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AudioMixerExtensionTests", dependencies: ["AudioMixerExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
