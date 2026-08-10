// swift-tools-version:6.0
import PackageDescription

var products: [Product] = [
    .library(name: "EdithCore", targets: ["EdithCore"])
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(
        name: "EdithCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "EdithCoreTests",
        dependencies: ["EdithCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

#if os(macOS)
products += [
    .library(name: "Edith", targets: ["Edith"]),
    .library(name: "EdithKit", targets: ["EdithKit"]),
    .library(name: "EdithCLI", targets: ["EdithCLI"]),
    .library(name: "Highlighter", targets: ["Highlighter"]),
]

dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.15.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
]

targets += [
    .target(
        name: "EdithKit",
        dependencies: ["EdithCore"],
        resources: [.process("Resources")],
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
        name: "edh",
        dependencies: ["EdithCLI"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "Edith",
        dependencies: [
            "EdithKit",
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            "Highlighter",
        ],
        resources: [.copy("Resources/appicon.png")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "EdithMain",
        dependencies: ["Edith"],
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
        dependencies: ["EdithKit"],
        resources: [.copy("MenuBar.png")],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "EdithTests",
        dependencies: [
            "EdithCore", "Edith", "EdithKit", "EdithHelper", "EdithCLI", "Highlighter",
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif

#if os(Linux)
products += [
    .executable(name: "edith-linux", targets: ["EdithLinux"])
]

targets += [
    .systemLibrary(
        name: "CGTK",
        pkgConfig: "gtk4",
        providers: [.apt(["libgtk-4-dev"])]
    ),
    .executableTarget(
        name: "EdithLinux",
        dependencies: ["EdithCore", "CGTK"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif

let package = Package(
    name: "Edith",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
