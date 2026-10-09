// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithExtensions",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "KeepAwakeExtension", path: "keepAwake", exclude: ["Tests", "Runtime.swift"]),
        .testTarget(
            name: "KeepAwakeExtensionTests", dependencies: ["KeepAwakeExtension"],
            path: "keepAwake/Tests"),
        .target(
            name: "FocusDimExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "focusDim", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FocusDimExtensionTests", dependencies: ["FocusDimExtension"],
            path: "focusDim/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "WindowSweatersExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "windowSweaters", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "WindowSweatersExtensionTests", dependencies: ["WindowSweatersExtension"],
            path: "windowSweaters/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "ColorPickerExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "colorPicker", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ColorPickerExtensionTests", dependencies: ["ColorPickerExtension"],
            path: "colorPicker/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "KeystrokeHighlightExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "keystrokeHighlight", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "KeystrokeHighlightExtensionTests", dependencies: ["KeystrokeHighlightExtension"],
            path: "keystrokeHighlight/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "SystemStatsExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "systemStats", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemStatsExtensionTests", dependencies: ["SystemStatsExtension"],
            path: "systemStats/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "MicMuteExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "micMute", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MicMuteExtensionTests", dependencies: ["MicMuteExtension"],
            path: "micMute/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "EmojiExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "emoji", exclude: ["Tests", "Runtime.swift"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EmojiExtensionTests", dependencies: ["EmojiExtension"],
            path: "emoji/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
