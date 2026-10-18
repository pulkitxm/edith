// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MachinesUI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ExtensionSupport"),
        .package(path: "../terminal/Native"),
        .package(path: "../fixtureSupport"),
    ],
    targets: [
        .target(
            name: "MachinesExtension",
            dependencies: [
                .product(name: "EdithExtensionDocuments", package: "ExtensionSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "GhosttyTerminal", package: "Native"),
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ], path: ".", exclude: ["Runtime.swift", "Tests"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MachinesExtensionTests", dependencies: ["MachinesExtension"],
            path: "Tests", exclude: ["UI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MachinesExtensionUITests", dependencies: ["MachinesExtension"],
            path: "Tests/UI", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
