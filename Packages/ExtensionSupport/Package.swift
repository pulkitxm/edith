// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtensionSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EdithExtensionSupport", type: .static, targets: ["EdithExtensionSupport"]),
        .library(name: "EdithExtensionUI", type: .static, targets: ["EdithExtensionUI"]),
        .library(
            name: "EdithExtensionDocuments", type: .static, targets: ["EdithExtensionDocuments"]),
        .library(name: "EdithExtensionArchive", type: .static, targets: ["EdithExtensionArchive"]),
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")],
    targets: [
        .target(
            name: "EdithExtensionArchive",
            dependencies: [
                "EdithExtensionUI", .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionArchiveTests", dependencies: ["EdithExtensionArchive"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "EdithExtensionSupport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EdithExtensionUI", dependencies: ["EdithExtensionSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EdithExtensionDocuments", dependencies: ["EdithExtensionUI"],
            resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionDocumentsTests", dependencies: ["EdithExtensionDocuments"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionSupportTests", dependencies: ["EdithExtensionSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithExtensionUITests", dependencies: ["EdithExtensionUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
