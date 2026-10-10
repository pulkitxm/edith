// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SystemExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "SystemExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemExtensionTests", dependencies: ["SystemExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
