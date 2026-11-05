// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithIcons",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EdithIcons", targets: ["EdithIcons"])
    ],
    targets: [
        .target(
            name: "EdithIcons",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-enable-library-evolution", "-emit-module-interface"]),
            ]),
        .testTarget(
            name: "EdithIconsTests", dependencies: ["EdithIcons"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
