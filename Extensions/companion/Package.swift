// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CompanionExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "CompanionExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CompanionExtensionTests", dependencies: ["CompanionExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
