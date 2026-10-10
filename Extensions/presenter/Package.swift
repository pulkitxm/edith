// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PresenterExtension",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "PresenterExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PresenterExtensionTests", dependencies: ["PresenterExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
