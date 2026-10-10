// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithExtensions",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/ExtensionSupport"),
        .package(path: "../Packages/EdithDocsWorker"),
    ],
    targets: [
        .target(
            name: "LidAwakeExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "lidAwake",
            exclude: [
                "Tests", "Runtime.swift", "Package.swift",
                "Privileged/LidAwakePrivilegedRuntime.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LidAwakeExtensionTests", dependencies: ["LidAwakeExtension"],
            path: "lidAwake/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "DownloadsExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "downloads", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "DownloadsExtensionTests", dependencies: ["DownloadsExtension"],
            path: "downloads/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),

        .target(
            name: "SEOAuditExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "seoAudit", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SEOAuditExtensionTests", dependencies: ["SEOAuditExtension"],
            path: "seoAudit/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CodeStatsExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "codeStats", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CodeStatsExtensionTests", dependencies: ["CodeStatsExtension"],
            path: "codeStats/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "QuinjetExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "quinjet",
            exclude: [
                "Tests", "Views", "ViewModels", "Models/QuinjetLaunchModels.swift",
                "Services/QuinjetSessionBridge.swift", "Package.swift", "Runtime.swift",
            ], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "QuinjetExtensionTests", dependencies: ["QuinjetExtension"],
            path: "quinjet/Tests/Core", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "HerdrExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "herdr",
            exclude: ["Tests", "Views", "ViewModels", "Package.swift", "Runtime.swift"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HerdrExtensionTests", dependencies: ["HerdrExtension"],
            path: "herdr/Tests/Core", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LaTeXExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport"), .product(name: "EdithExtensionArchive", package: "ExtensionSupport")],
            path: "latex", exclude: ["Tests", "Runtime.swift", "Package.swift"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LaTeXExtensionTests", dependencies: ["LaTeXExtension"],
            path: "latex/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CompanionExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "companion", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CompanionExtensionTests", dependencies: ["CompanionExtension"],
            path: "companion/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "BifrostExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "bifrost", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BifrostExtensionTests", dependencies: ["BifrostExtension"],
            path: "bifrost/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),

        .target(
            name: "MachinesExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "machines", exclude: ["Tests", "Runtime.swift", "UI", "Package.swift"],
            resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MachinesExtensionTests", dependencies: ["MachinesExtension"],
            path: "machines/Tests", exclude: ["UI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "ClipboardExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "clipboard", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ClipboardExtensionTests", dependencies: ["ClipboardExtension"],
            path: "clipboard/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "UsageExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "usage", exclude: ["Tests", "Runtime.swift"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "UsageExtensionTests", dependencies: ["UsageExtension"],
            path: "usage/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "NotchShelfExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "notchShelf", exclude: ["Tests", "Runtime.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "NotchShelfExtensionTests", dependencies: ["NotchShelfExtension"],
            path: "notchShelf/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "KeepAwakeExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "keepAwake", exclude: ["Tests", "Runtime.swift"]),
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
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
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
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
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
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "emoji", exclude: ["Tests", "Runtime.swift"], resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EmojiExtensionTests", dependencies: ["EmojiExtension"],
            path: "emoji/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "HomebrewExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "homebrew", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HomebrewExtensionTests", dependencies: ["HomebrewExtension"],
            path: "homebrew/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CalendarExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "calendar", exclude: ["Tests"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CalendarExtensionTests", dependencies: ["CalendarExtension"],
            path: "calendar/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "JevExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "jev", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "JevExtensionTests", dependencies: ["JevExtension"],
            path: "jev/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "PresenterExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "presenter", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PresenterExtensionTests", dependencies: ["PresenterExtension"],
            path: "presenter/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "SystemExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "system", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SystemExtensionTests", dependencies: ["SystemExtension"],
            path: "system/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "TimeLapseExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "timeLapse", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "TimeLapseExtensionTests", dependencies: ["TimeLapseExtension"],
            path: "timeLapse/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "CleanerExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "cleaner", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CleanerExtensionTests", dependencies: ["CleanerExtension"],
            path: "cleaner/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "AppMaintenanceExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: "appMaintenance", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AppMaintenanceExtensionTests", dependencies: ["AppMaintenanceExtension"],
            path: "appMaintenance/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),

        .target(
            name: "BlitzTreeExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "blitztree", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BlitzTreeExtensionTests", dependencies: ["BlitzTreeExtension"],
            path: "blitztree/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),

        .target(
            name: "PluginsExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport"), .product(name: "EdithExtensionDocuments", package: "ExtensionSupport")],
            path: "plugins", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PluginsExtensionTests", dependencies: ["PluginsExtension"],
            path: "plugins/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "MusicExtension",
            dependencies: [.product(name: "EdithExtensionUI", package: "ExtensionSupport")],
            path: "music", exclude: ["Tests", "Runtime.swift", "Native", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MusicExtensionTests", dependencies: ["MusicExtension"],
            path: "music/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "DocsExtension",
            dependencies: [
                .product(name: "EdithExtensionCommands", package: "ExtensionSupport"),
                .product(name: "EdithExtensionDocuments", package: "ExtensionSupport"),
                .product(name: "EdithDocsWorker", package: "EdithDocsWorker"),
            ], path: "docs", exclude: ["Tests", "Runtime.swift", "Package.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "DocsExtensionTests", dependencies: ["DocsExtension"],
            path: "docs/Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
