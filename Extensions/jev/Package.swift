// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JevExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "ExtensionSupport",
            path: "../../Packages/ExtensionSupport")
    ],
    targets: [
        .target(
            name: "JevExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "JevExtensionTests", dependencies: ["JevExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
