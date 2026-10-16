// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DocsExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"),
        .package(path: "../../Packages/EdithDocsWorker"),
    ],
    targets: [
        .target(
            name: "DocsExtension",
            dependencies: [
                .product(name: "EdithExtensionDocuments", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithDocsWorker", package: "EdithDocsWorker"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "DocsExtensionTests", dependencies: ["DocsExtension"],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
