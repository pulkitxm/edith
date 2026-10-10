// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HomebrewExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "HomebrewExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HomebrewExtensionTests", dependencies: ["HomebrewExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
