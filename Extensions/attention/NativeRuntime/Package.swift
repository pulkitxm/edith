// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AttentionNative",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AttentionNative", type: .dynamic, targets: ["AttentionNative"])],
    dependencies: [
        .package(path: "../../fixtureSupport"),
        .package(path: "../../../local/extension-support/attention_native"),
        .package(path: "../../../Packages/ExtensionSupport"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AttentionNative",
            dependencies: [
                .product(
                    name: "WorkerFixtureSupport", package: "fixtureSupport",
                    moduleAliases: ["WorkerFixtureSupport": "AttentionWorkerFixtureSupport"]),
                .product(
                    name: "EdithExtensionSupport_attention_native", package: "attention_native"),
                .product(name: "EdithExtensionKit", package: "ExtensionSupport"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources/ChromeExtension")],
            swiftSettings: [
                .swiftLanguageMode(.v5), .enableExperimentalFeature("CheckImplementationOnly"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks",
                ])
            ]),
        .testTarget(
            name: "AttentionNativeTests",
            dependencies: [
                "AttentionNative",
                .product(
                    name: "WorkerFixtureTestSupport", package: "fixtureSupport",
                    moduleAliases: ["WorkerFixtureSupport": "AttentionWorkerFixtureSupport"]),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
