// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KeepAwakeExtension",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"), .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "KeepAwakeExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: ".", exclude: ["Tests"]),
        .testTarget(
            name: "KeepAwakeExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "KeepAwakeExtension",
            ],
            path: "Tests"),
    ]
)
