// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AudioMixerExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "AudioMixerExtension",
            dependencies: [
                .product(name: "EdithExtensionUI", package: "ExtensionSupport")
            ], path: ".", exclude: ["Tests", "NativeRuntime"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AudioMixerExtensionTests", dependencies: ["AudioMixerExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
