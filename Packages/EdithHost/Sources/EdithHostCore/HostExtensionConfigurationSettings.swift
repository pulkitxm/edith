import EdithExtensionSupport
import Foundation

enum HostExtensionConfigurationSettings {
    static let all: [HostCLISetting] = micMute + focusDim + hinge + windowSweaters

    private static let micMute: [HostCLISetting] = [
        .init(
            AppStorageKeys.Mic.muted, .bool, group: "micmute",
            summary: "Microphone muted right now.", fallback: .bool(false), readOnly: true),
        .init(
            AppStorageKeys.Mic.muteEnabled, .bool, group: "micmute",
            summary: "Mic Mute extension: system-wide microphone kill switch.",
            fallback: .bool(false)),
        .init(
            AppStorageKeys.Mic.muteInMenuBar, .bool, group: "micmute",
            summary: "Show the mic mute indicator in the menu bar."),
        .init(
            "micHotKeyCode", .int, group: "micmute",
            summary: "Virtual key code of the mic mute shortcut."),
        .init(
            "micHotKeyMods", .int, group: "micmute",
            summary: "Carbon modifier mask of the mic mute shortcut."),
        .init(
            "micHotKeyLabel", .string, group: "micmute",
            summary: "Printable label for the mic mute shortcut."),
    ]

    private static let focusDim: [HostCLISetting] = [
        .init(
            "focusDimActive", .bool, group: "focusdim", summary: "Focus dim on right now.",
            fallback: .bool(false)),
        .init(
            "focusDimEnabled", .bool, group: "focusdim",
            summary: "Focus Dim extension: dim everything behind the active app.",
            fallback: .bool(false)),
        .init(
            AppStorageKeys.FocusDim.intensity, .number, group: "focusdim",
            summary: "Dim strength from 0 to 1.", fallback: .number(0.5)),
        .init(
            AppStorageKeys.FocusDim.animationDuration, .number, group: "focusdim",
            summary: "Seconds the dim takes to fade."),
        .init(
            AppStorageKeys.FocusDim.otherDisplaysMode, .string, group: "focusdim",
            summary: "How other displays are treated.",
            allowed: ["perScreenFront", "dimUnfocused"], fallback: .string("perScreenFront")),
        .init(
            AppStorageKeys.FocusDim.hotKeyCode, .int, group: "focusdim",
            summary: "Virtual key code of the focus dim shortcut."),
        .init(
            AppStorageKeys.FocusDim.hotKeyMods, .int, group: "focusdim",
            summary: "Carbon modifier mask of the focus dim shortcut."),
        .init(
            AppStorageKeys.FocusDim.hotKeyLabel, .string, group: "focusdim",
            summary: "Printable label for the focus dim shortcut."),
    ]

    private static let hinge: [HostCLISetting] = [
        .init(
            "hingeActive", .bool, group: "hinge", summary: "Hinge fold on right now.",
            fallback: .bool(false)),
        .init(
            "hingeEnabled", .bool, group: "hinge",
            summary: "Hinge extension: fold the desktop as the MacBook lid closes.",
            fallback: .bool(false)),
        .init(
            "hingeOpenAngle", .number, group: "hinge",
            summary: "Lid angle, in degrees, that counts as fully open.",
            fallback: .number(100)),
        .init(
            "hingeEffectStrength", .number, group: "hinge",
            summary: "Fold strength from 0.25 to 1.", fallback: .number(1)),
        .init(
            "hingeSideFill", .string, group: "hinge",
            summary: "What fills the sides of the fold.", allowed: ["blur", "black"],
            fallback: .string("blur")),
        .init(
            "hingeCropsTop", .bool, group: "hinge",
            summary: "Crop the top of the desktop as it folds.", fallback: .bool(true)),
        .init(
            "hingeBlursByDistance", .bool, group: "hinge",
            summary: "Blur the fold more as it moves away.", fallback: .bool(true)),
        .init(
            "hingeHotKeyCode", .int, group: "hinge",
            summary: "Virtual key code of the Hinge shortcut."),
        .init(
            "hingeHotKeyMods", .int, group: "hinge",
            summary: "Carbon modifier mask of the Hinge shortcut."),
        .init(
            "hingeHotKeyLabel", .string, group: "hinge",
            summary: "Printable label for the Hinge shortcut."),
    ]

    private static let windowSweaters: [HostCLISetting] = [
        .init(
            AppStorageKeys.WindowSweaters.enabled, .bool, group: "sweaters",
            summary: "Window Sweaters extension: knitted borders around your windows.",
            fallback: .bool(false)),
        .init(
            AppStorageKeys.WindowSweaters.active, .bool, group: "sweaters",
            summary: "Sweaters on right now. Turn off to pause without disabling.",
            fallback: .bool(true)),
        .init(
            AppStorageKeys.WindowSweaters.pattern, .string, group: "sweaters",
            summary: "by-app, none, or a built-in pattern name.", fallback: .string("by-app")),
        .init(
            AppStorageKeys.WindowSweaters.stitch, .string, group: "sweaters",
            summary: "Plain knitting stitch used where no pattern applies.",
            allowed: ["stockinette", "rib", "garter"], fallback: .string("stockinette")),
        .init(
            AppStorageKeys.WindowSweaters.basket, .string, group: "sweaters",
            summary: "Colourway used by apps without a curated sweater.",
            allowed: ["dopamine", "neon", "punch", "wool", "sorbet", "forest", "mono"],
            fallback: .string("wool")),
        .init(
            AppStorageKeys.WindowSweaters.borderWidth, .number, group: "sweaters",
            summary: "Border width in points, 2 to 60.", fallback: .number(12)),
        .init(
            AppStorageKeys.WindowSweaters.gauge, .number, group: "sweaters",
            summary: "Stitch rows across the band; fewer rows knit chunkier.",
            fallback: .number(6)),
        .init(
            AppStorageKeys.WindowSweaters.anchor, .string, group: "sweaters",
            summary: "Where each side's pattern repeat starts.",
            allowed: ["corner", "centre"], fallback: .string("corner")),
        .init(
            AppStorageKeys.WindowSweaters.order, .string, group: "sweaters",
            summary: "Whether the sweater sits behind or in front of the window.",
            allowed: ["below", "above"], fallback: .string("below")),
        .init(
            AppStorageKeys.WindowSweaters.unfocusedDim, .number, group: "sweaters",
            summary: "How far unfocused sweaters are darkened, 0 to 0.9.", fallback: .number(0)),
        .init(
            AppStorageKeys.WindowSweaters.accessibilityFocus, .bool, group: "sweaters",
            summary: "Read the focused window through Accessibility instead of the server.",
            fallback: .bool(false)),
        .init(
            AppStorageKeys.WindowSweaters.excludedApps, .string, group: "sweaters",
            summary: "Comma-separated app names that never get a sweater."),
    ]
}
