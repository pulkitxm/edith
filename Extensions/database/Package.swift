// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DatabaseExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "DatabaseEngine"),
    ],
    targets: [
        .target(
            name: "DatabaseExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "DatabaseEngine", package: "DatabaseEngine"),
            ],
            path: ".", exclude: ["Tests", "Runtime.swift", "DatabaseEngine", "test.mjs"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "DatabaseExtensionTests", dependencies: ["DatabaseExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
