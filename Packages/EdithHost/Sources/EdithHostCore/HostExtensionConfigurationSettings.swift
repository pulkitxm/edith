import EdithExtensionSupport
import Foundation

enum HostExtensionConfigurationSettings {
    static let all: [HostCLISetting] =
        [
            ("micMute", micMute), ("focusDim", focusDim), ("hinge", hinge),
            ("windowSweaters", windowSweaters), ("presenter", presenter),
            ("keystrokeHighlight", keystrokeHighlight), ("keepAwake", keepAwake),
            ("lidAwake", lidAwake), ("appMaintenance", appMaintenance), ("cleaner", cleaner),
            ("homebrew", homebrew), ("system", system),
        ].flatMap { owner, settings in settings.map { $0.owned(by: owner) } }

    private static let presenterPrivacy: [(String, String)] = [
        ("Music", "Blur track names, artwork and folders."),
        ("Money", "Blur spend figures."),
        ("Usage", "Blur usage percentages."),
        ("Calendar", "Blur calendar entries."),
        ("Agents", "Hide live Herdr titles and blur attached terminals."),
        ("Attention", "Blur attention activity, titles and sites."),
        ("Camera", "Blur the virtual camera picture and personal backdrops."),
        ("Studio", "Blur Studio files, projects and previews."),
        ("Database", "Blur database connections and rows."),
        ("Memory", "Blur memory chats, notes and captures."),
        ("Fleet", "Blur machine names, files and terminals."),
        ("Review", "Blur review sessions."),
        ("SiteAudit", "Blur site audit projects and pages."),
        ("RunningApps", "Blur running app names and icons."),
        ("Shelf", "Blur files parked on the shelf."),
        ("Browser", "Blur the notch browser, including the address and page titles."),
    ]

    private static let presenter: [HostCLISetting] =
        [
            .init(
                AppStorageKeys.Presenter.enabled, .bool, group: "presenter",
                summary: "Presenter extension is on. Change it with `ed extensions enable`.",
                fallback: .bool(false), readOnly: true),
            .init(
                AppStorageKeys.Presenter.mode, .bool, group: "presenter",
                summary: "Presenter mode on right now.", fallback: .bool(false)),
            .init(
                AppStorageKeys.Presenter.autoActive, .bool, group: "presenter",
                summary: "A share is being detected right now.", fallback: .bool(false),
                readOnly: true),
            .init(
                AppStorageKeys.Presenter.autoPaused, .bool, group: "presenter",
                summary: "Auto presenter mode is paused until the current share ends.",
                fallback: .bool(false), readOnly: true),
            .init(
                AppStorageKeys.Presenter.autoReason, .string, group: "presenter",
                summary: "Why auto presenter mode turned on.", readOnly: true),
            .init(
                AppStorageKeys.Presenter.autoEnabled, .bool, group: "presenter",
                summary: "Turn presenter mode on automatically when a share is detected."),
            .init(
                AppStorageKeys.Presenter.detectRecording, .bool, group: "presenter",
                summary: "Treat screen recording as a share."),
            .init(
                AppStorageKeys.Presenter.detectScreenSharing, .bool, group: "presenter",
                summary: "Treat screen sharing as a share."),
            .init(
                AppStorageKeys.Presenter.detectMirroring, .bool, group: "presenter",
                summary: "Treat display mirroring as a share."),
            .init(
                AppStorageKeys.Presenter.askJev, .bool, group: "presenter",
                summary:
                    "Ask Jev whether on-screen windows look like a shared screen. Sends window titles to TypeSafe.",
                fallback: .bool(false)),
            .init(
                AppStorageKeys.Presenter.hideMenuBarNumbers, .bool, group: "presenter",
                summary: "Hide menu bar percentages while presenting."),
        ]
        + presenterPrivacy.map { name, summary in
            .init("presenterBlur" + name, .bool, group: "presenter", summary: summary)
        } + [
            .init(
                "presenterHotKeyCode", .int, group: "presenter",
                summary: "Virtual key code of the presenter shortcut."),
            .init(
                "presenterHotKeyMods", .int, group: "presenter",
                summary: "Carbon modifier mask of the presenter shortcut."),
            .init(
                "presenterHotKeyLabel", .string, group: "presenter",
                summary: "Printable label for the presenter shortcut."),
        ]

    private static let keystrokeHighlight: [HostCLISetting] = [
        .init(
            AppStorageKeys.KeystrokeHighlight.enabled, .bool, group: "keystrokes",
            summary: "Keystroke Highlight extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            AppStorageKeys.KeystrokeHighlight.active, .bool, group: "keystrokes",
            summary: "Show key presses in an on-screen overlay.", fallback: .bool(false)),
        .init(
            AppStorageKeys.KeystrokeHighlight.duration, .number, group: "keystrokes",
            summary: "Seconds each key press remains on screen.", fallback: .number(1.5)),
        .init(
            AppStorageKeys.KeystrokeHighlight.position, .string, group: "keystrokes",
            summary: "Screen edge used for the key press overlay.", allowed: ["top", "bottom"],
            fallback: .string("bottom")),
        .init(
            AppStorageKeys.KeystrokeHighlight.hotKeyCode, .int, group: "keystrokes",
            summary: "Virtual key code of the keystroke highlight shortcut.",
            fallback: .integer(40)),
        .init(
            AppStorageKeys.KeystrokeHighlight.hotKeyMods, .int, group: "keystrokes",
            summary: "Carbon modifier mask of the keystroke highlight shortcut.",
            fallback: .integer(6400)),
        .init(
            AppStorageKeys.KeystrokeHighlight.hotKeyLabel, .string, group: "keystrokes",
            summary: "Printable label for the keystroke highlight shortcut.",
            fallback: .string("\u{2303}\u{2325}\u{2318}K")),
    ]

    private static let keepAwake: [HostCLISetting] = [
        .init(
            AppStorageKeys.General.keepAwakeEnabled, .bool, group: "system",
            summary: "Keep Awake extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            AppStorageKeys.General.preventSleep, .bool, group: "system",
            summary: "Keep the Mac awake (Keep Awake).", fallback: .bool(false)),
    ]

    private static let lidAwake: [HostCLISetting] = [
        .init(
            "lidAwakeEnabled", .bool, group: "system",
            summary: "Lid Awake extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            "lidAwakeRestoreOnQuit", .bool, group: "system",
            summary: "Restore normal lid-close sleep when Edith quits.", fallback: .bool(true)),
        .init(
            "lidAwakeSession", .string, group: "system",
            summary: "Session used when Lid Awake starts.",
            allowed: [
                "indefinite", "fifteenMinutes", "thirtyMinutes", "oneHour", "twoHours",
                "untilLidReopens",
            ], fallback: .string("indefinite")),
        .init(
            "lidAwakeBatteryThreshold", .int, group: "system",
            summary: "Battery percentage below which Lid Awake pauses; 0 disables it.",
            minimum: 0, maximum: 100, fallback: .integer(0)),
        .init(
            "lidAwakeActive", .bool, group: "system",
            summary: "Whether Lid Awake is currently preventing lid-close sleep.",
            fallback: .bool(false), readOnly: true),
    ]

    private static let appMaintenance: [HostCLISetting] = [
        .init(
            AppStorageKeys.AppMaintenance.enabled, .bool, group: "system",
            summary: "App Maintenance extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            AppStorageKeys.AppMaintenance.installDestination, .string, group: "system",
            summary: "Default disk image installation destination.",
            allowed: ["user", "system"], fallback: .string("user")),
        .init(
            AppStorageKeys.AppMaintenance.updateAutoRefresh, .bool, group: "system",
            summary: "Refresh App Update Center automatically.", fallback: .bool(false)),
        .init(
            AppStorageKeys.AppMaintenance.updateRefreshInterval, .number, group: "system",
            summary: "Seconds between enabled App Update Center refreshes.",
            fallback: .number(86_400)),
        .init(
            AppStorageKeys.AppMaintenance.updateNotifications, .bool, group: "system",
            summary: "Notify after automatic refreshes find new updates.", fallback: .bool(true)),
        .init(
            AppStorageKeys.AppMaintenance.updateConcurrency, .int, group: "system",
            summary: "Maximum updates running together.", fallback: .integer(2)),
        .init(
            AppStorageKeys.AppMaintenance.updateRetries, .int, group: "system",
            summary: "Retries after an update fails.", fallback: .integer(1)),
    ]

    private static let system: [HostCLISetting] = [
        .init(
            AppStorageKeys.Tabs.systemEnabled, .bool, group: "system",
            summary: "System extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            "systemAppsSort", .string, group: "system", summary: "Running apps sort column.",
            fallback: .string("memory")),
        .init(
            "systemAppsSortAsc", .bool, group: "system", summary: "Sort running apps ascending.",
            fallback: .bool(false)),
    ]

    private static let cleaner: [HostCLISetting] = [
        .init(
            AppStorageKeys.Cleaner.enabled, .bool, group: "cleaner",
            summary: "Cleaner extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            "cleanerSelectedDrives", .stringList, group: "cleaner",
            summary: "Volumes the disk cleaner scans."),
        .init(
            "cleanerCustomFolders", .stringList, group: "cleaner",
            summary: "Extra folders added to the disk cleaner."),
        .init(
            "cleanerCategoryDefaults", .map, group: "cleaner",
            summary: "Per-category cleaner defaults."),
        .init(
            "cleanerSelectionOverrides", .map, group: "cleaner",
            summary: "Per-path cleaner selection overrides."),
    ]

    private static let homebrew: [HostCLISetting] = [
        .init(
            AppStorageKeys.Homebrew.enabled, .bool, group: "homebrew",
            summary: "Homebrew extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            AppStorageKeys.Homebrew.defaultKind, .string, group: "homebrew",
            summary: "Package kind selected when App Maintenance opens Packages.",
            allowed: ["formula", "cask"], fallback: .string("formula")),
    ]

    private static let micMute: [HostCLISetting] = [
        .init(
            AppStorageKeys.Mic.muted, .bool, group: "micmute",
            summary: "Microphone muted right now.", fallback: .bool(false), readOnly: true),
        .init(
            AppStorageKeys.Mic.muteEnabled, .bool, group: "micmute",
            summary: "Mic Mute extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
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
            summary: "Focus Dim extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
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
            summary: "Hinge extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
        .init(
            "hingeOpenAngle", .number, group: "hinge",
            summary: "Lid angle, in degrees, that counts as fully open.",
            fallback: .number(100), readOnly: true),
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
            summary: "Window Sweaters extension is on. Change it with `ed extensions enable`.",
            fallback: .bool(false), readOnly: true),
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
