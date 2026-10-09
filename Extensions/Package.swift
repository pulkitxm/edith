// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithExtensions",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "KeepAwakeExtension", path: "keepAwake", exclude: ["Tests", "Runtime.swift"]),
        .testTarget(
            name: "KeepAwakeExtensionTests", dependencies: ["KeepAwakeExtension"],
            path: "keepAwake/Tests"),
        .target(
            name: "FocusDimExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "focusDim", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FocusDimExtensionTests", dependencies: ["FocusDimExtension"],
            path: "focusDim/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
