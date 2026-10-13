// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BlitzTreeExtension", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"),
        .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "BlitzTreeExtension",
            dependencies: [
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BlitzTreeExtensionTests", dependencies: ["BlitzTreeExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
