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
            name: "FocusDimExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "focusDim", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FocusDimExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "FocusDimExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "focusDim/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "HingeExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "hinge", exclude: ["Tests", "Runtime.swift", "LICENSE"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HingeExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "HingeExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "hinge/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "WindowSweatersExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "windowSweaters", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "WindowSweatersExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "WindowSweatersExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "windowSweaters/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "ColorPickerExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "colorPicker", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ColorPickerExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "ColorPickerExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "colorPicker/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "KeystrokeHighlightExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "keystrokeHighlight", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "KeystrokeHighlightExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "KeystrokeHighlightExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "keystrokeHighlight/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "MicMuteExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionUI", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "micMute", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MicMuteExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "MicMuteExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "micMute/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EmojiExtension",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "emoji", exclude: ["Tests", "Runtime.swift"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EmojiExtensionTests",
            dependencies: [
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "WorkerFixtureTestSupport", package: "fixtureSupport"),
                "EmojiExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "emoji/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CalendarExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithExtensionSupport", package: "ExtensionSupport"),
            ],
            path: "calendar", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CalendarExtensionTests",
            dependencies: [
                "CalendarExtension",
                .product(name: "EdithExtensionTestSupport", package: "ExtensionSupport"),
            ],
            path: "calendar/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
