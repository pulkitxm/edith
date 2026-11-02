// swift-tools-version:6.0
import PackageDescription

let shared: [SwiftSetting] = [
    .swiftLanguageMode(.v5), .unsafeFlags(["-enable-library-evolution", "-emit-module-interface"]),
]

let package = Package(
    name: "ExtensionSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "EdithExtensionKit", type: .dynamic,
            targets: [
                "EdithExtensionCore", "EdithExtensionSupport", "EdithExtensionUI",
                "EdithExtensionDocuments",
                "EdithExtensionFiles", "EdithExtensionArchive", "EdithExtensionAccounts",
                "EdithExtensionCommands",
            ]),
        .library(
            name: "EdithExtensionAccounts", type: .static, targets: ["EdithExtensionAccounts"]),
        .library(name: "EdithExtensionCore", type: .static, targets: ["EdithExtensionCore"]),
        .library(name: "EdithExtensionSupport", type: .static, targets: ["EdithExtensionSupport"]),
        .library(name: "EdithExtensionUI", type: .static, targets: ["EdithExtensionUI"]),
        .library(
            name: "EdithExtensionCommands", type: .static, targets: ["EdithExtensionCommands"]),
        .library(
            name: "EdithExtensionDocuments", type: .static, targets: ["EdithExtensionDocuments"]),
        .library(name: "EdithExtensionFiles", type: .static, targets: ["EdithExtensionFiles"]),
        .library(name: "EdithExtensionArchive", type: .static, targets: ["EdithExtensionArchive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "EdithExtensionAccounts", swiftSettings: shared),
        .testTarget(
            name: "EdithExtensionAccountsTests", dependencies: ["EdithExtensionAccounts"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EdithExtensionArchive",
            dependencies: [
                "EdithExtensionCore", "EdithExtensionUI",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: shared),
        .testTarget(
            name: "EdithExtensionArchiveTests", dependencies: ["EdithExtensionArchive"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "EdithExtensionCore", swiftSettings: shared),
        .target(
            name: "EdithExtensionSupport", dependencies: ["EdithExtensionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EdithExtensionCommands",
            dependencies: [
                "EdithExtensionCore", "EdithExtensionUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ], swiftSettings: shared),
        .testTarget(
            name: "EdithExtensionCommandsTests", dependencies: ["EdithExtensionCommands"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EdithExtensionUI", dependencies: ["EdithExtensionCore"],
            swiftSettings: shared),
        .target(
            name: "EdithExtensionDocuments",
            dependencies: ["EdithExtensionCore", "EdithExtensionUI"],
            resources: [.process("Resources")], swiftSettings: shared),
        .target(
            name: "EdithExtensionFiles",
            dependencies: ["EdithExtensionCore", "EdithExtensionUI", "EdithExtensionDocuments"],
            swiftSettings: shared),
        .testTarget(
            name: "EdithExtensionFilesTests", dependencies: ["EdithExtensionFiles"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionDocumentsTests", dependencies: ["EdithExtensionDocuments"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionSupportTests",
            dependencies: ["EdithExtensionCore", "EdithExtensionSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionUITests", dependencies: ["EdithExtensionUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
