// swift-tools-version:6.0
import PackageDescription

let products: [Product] = [
    .library(name: "EdithCore", targets: ["EdithCore"]),
    .library(name: "EdithDatabase", targets: ["EdithDatabase"]),
    .library(name: "Edith", targets: ["Edith"]),
    .library(name: "EdithKit", targets: ["EdithKit"]),
    .library(name: "EdithCLI", targets: ["EdithCLI"]),
    .library(name: "Highlighter", targets: ["Highlighter"]),
    .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    .executable(name: "EdithLidAwakeHelper", targets: ["EdithLidAwakeHelper"]),
]

let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.18.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
]

let targets: [Target] = [
    .target(
        name: "EdithCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "EdithCoreTests",
        dependencies: ["EdithCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "EdithDatabase",
        dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "EdithDatabaseTests",
        dependencies: ["EdithDatabase"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "EdithKit",
        dependencies: ["EdithCore", "EdithLidAwakeSupport"],
        resources: [
            .process("Resources"),
            .copy("ChromeExtension"),
            .copy("../Edith/Resources/appicon.png"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "EdithLidAwakeSupport",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "Highlighter",
        dependencies: ["EdithKit"],
        path: "Vendor/Highlighter",
        exclude: ["LICENCE.md"],
        sources: ["Sources"],
        resources: [.process("Resources")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "EdithCLI",
        dependencies: [
            "EdithCore",
            "EdithKit",
            "EdithLidAwakeSupport",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "ed",
        dependencies: ["EdithCLI"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "EdithLidAwakeHelper",
        dependencies: ["EdithLidAwakeSupport"],
        path: "Sources/EdithLidAwakeHelper",
        exclude: ["Info.plist"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/EdithLidAwakeHelper/Info.plist",
            ])
        ]
    ),
    .executableTarget(
        name: "UsageSnapshotCrashDriver",
        dependencies: ["EdithKit"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .binaryTarget(
        name: "GhosttyKit",
        path: "vendor/GhosttyKit.xcframework"
    ),
    .target(
        name: "GhosttyTerminal",
        dependencies: ["GhosttyKit"],
        resources: [.copy("Resources/Fonts")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "Edith",
        dependencies: [
            "EdithKit",
            "EdithLidAwakeSupport",
            "GhosttyTerminal",
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            "Highlighter",
        ],
        exclude: ["Resources"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "EdithMain",
        dependencies: ["Edith", "EdithCLI"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            ])
        ]
    ),
    .executableTarget(
        name: "EdithFiles",
        dependencies: ["Edith"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker",
                "@executable_path/../../../../../Frameworks",
            ])
        ]
    ),
    .executableTarget(
        name: "EdithHelper",
        dependencies: ["EdithKit", "EdithLidAwakeSupport"],
        resources: [.copy("MenuBar.png")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "EdithTests",
        dependencies: [
            "EdithCore", "Edith", "EdithKit", "EdithLidAwakeSupport", "EdithHelper",
            "EdithCLI", "Highlighter", "ed", "UsageSnapshotCrashDriver",
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

let package = Package(
    name: "Edith",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
