// swift-tools-version:6.0
import PackageDescription
import Foundation

let supportAliases = [
    "EdithExtensionSupport": "EdithExtensionSupport_attention_native",
    "EdithExtensionUI": "EdithExtensionUI_attention_native",
]

let package = Package(
    name: "AttentionNative",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AttentionNative", type: .dynamic, targets: ["AttentionNative"])],
    dependencies: [
        .package(path: "../../../Packages/ExtensionSupport"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AttentionNative",
            dependencies: [
                .product(
                    name: "EdithExtensionUI", package: "ExtensionSupport",
                    moduleAliases: supportAliases),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources/ChromeExtension")],
            swiftSettings: [
                .swiftLanguageMode(.v5), .enableExperimentalFeature("CheckImplementationOnly"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_edith_extension_presentation_create"])
            ]),
        .testTarget(
            name: "AttentionNativeTests", dependencies: ["AttentionNative"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
