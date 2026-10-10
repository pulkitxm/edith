// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithExtensions",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/ExtensionSupport"), .package(path: "fixtureSupport"),
    ],
    targets: [
        .testTarget(
            name: "WorkerFixtureSupportTests",
            dependencies: [.product(name: "WorkerFixtureSupport", package: "fixtureSupport")],
            path: "fixtureSupport/Tests", exclude: ["Support"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "KeepAwakeExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "keepAwake", exclude: ["Tests"]),
        .testTarget(
            name: "KeepAwakeExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "KeepAwakeExtension",
            ],
            path: "keepAwake/Tests"),
        .target(
            name: "FocusDimExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "focusDim", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FocusDimExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "FocusDimExtension",
            ],
            path: "focusDim/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "WindowSweatersExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "windowSweaters", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "WindowSweatersExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "WindowSweatersExtension",
            ],
            path: "windowSweaters/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "ColorPickerExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ],
            path: "colorPicker", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ColorPickerExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "ColorPickerExtension",
            ],
            path: "colorPicker/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "KeystrokeHighlightExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "keystrokeHighlight", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "KeystrokeHighlightExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "KeystrokeHighlightExtension",
            ],
            path: "keystrokeHighlight/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "MicMuteExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
            ],
            path: "micMute", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MicMuteExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "MicMuteExtension",
            ],
            path: "micMute/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EmojiExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
            ],
            path: "emoji", exclude: ["Tests", "Runtime.swift"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EmojiExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "EmojiExtension",
            ],
            path: "emoji/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CalendarExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "calendar", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CalendarExtensionTests", dependencies: ["CalendarExtension"],
            path: "calendar/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
