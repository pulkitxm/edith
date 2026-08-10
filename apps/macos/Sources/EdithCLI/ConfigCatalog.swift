import EdithKit
import Foundation

public struct SettingDefinition: Equatable, Sendable {
    public enum ValueType: String, Equatable, Sendable {
        case bool
        case int
        case number
        case string
        case csv
        case stringList
        case map
    }

    public enum Scope: String, Equatable, Sendable {
        case shared
        case standard
    }

    public let key: String
    public let type: ValueType
    public let scope: Scope
    public let group: String
    public let summary: String
    public let allowed: [String]
    public let fallback: JSONValue
    public let readOnly: Bool

    public init(
        _ key: String, _ type: ValueType, group: String, summary: String,
        allowed: [String] = [], fallback: JSONValue = .null, scope: Scope = .shared,
        readOnly: Bool = false
    ) {
        self.key = key
        self.type = type
        self.scope = scope
        self.group = group
        self.summary = summary
        self.allowed = allowed
        self.fallback = fallback
        self.readOnly = readOnly
    }
}

public enum ConfigCatalog {
    public static let groups = [
        "appearance", "panel", "usage", "limits", "menubar", "alerts", "budget", "dashboard",
        "machines", "companion", "finder", "system", "cleaner", "music", "calendar", "clipboard",
        "notch", "focusdim", "presenter", "colorpicker", "micmute", "backup", "permissions",
        "terminal",
    ]

    public static let settings: [SettingDefinition] =
        appearance + panel + usageAndLimits
        + menuBar + alerts + budget + dashboard + machines + companion + finder + system + cleaner
        + music + calendar + clipboard + notch + focusDim + presenter + colorPicker + micMute
        + backup + permissions + terminal

    public static var keys: [String] { settings.map(\.key) }

    public static func definition(for key: String) -> SettingDefinition? {
        settings.first { $0.key == key }
    }

    public static func matching(prefix: String) -> [SettingDefinition] {
        guard !prefix.isEmpty else { return settings }
        return settings.filter { $0.key.hasPrefix(prefix) }
    }

    public static func inGroup(_ group: String) -> [SettingDefinition] {
        settings.filter { $0.group == group }
    }

    public static let extensionKeys: [String: String] = Dictionary(
        uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.defaultsKey) })

    private static let appearance: [SettingDefinition] = [
        SettingDefinition(
            "appearance", .string, group: "appearance",
            summary: "Window and panel appearance.", allowed: ["system", "light", "dark"],
            fallback: .string("system")),
        SettingDefinition(
            "theme", .string, group: "appearance", summary: "Accent palette name.",
            fallback: .string("default")),
        SettingDefinition(
            "lastPaletteTheme", .string, group: "appearance",
            summary: "Palette the theme picker restores when a custom accent is cleared."),
        SettingDefinition(
            "showDockIcon", .bool, group: "appearance",
            summary: "Show Edith in the Dock as well as the menu bar.", fallback: .bool(false)),
        SettingDefinition(
            "creditHidden", .bool, group: "appearance",
            summary: "Hide the credit line at the bottom of the panel.", fallback: .bool(false)),
        SettingDefinition(
            "homeClockZones", .csv, group: "appearance",
            summary: "Comma separated time zone identifiers shown on the Home clocks."),
    ]

    private static let panel: [SettingDefinition] = [
        SettingDefinition(
            "extensionsExpand", .string, group: "panel",
            summary: "Extension card the Extensions page scrolls to and opens next."),
        SettingDefinition(
            "settingsSection", .string, group: "panel",
            summary: "Settings section a deep link opens on."),
        SettingDefinition(
            "mainWindowZoom", .number, group: "panel",
            summary: "Main window zoom factor.", fallback: .double(1)),
        SettingDefinition(
            "onboardingCompleted", .bool, group: "panel",
            summary: "Whether the welcome tour has been finished or skipped.",
            fallback: .bool(false)),
        SettingDefinition(
            "EdithMainWindowFullScreen", .bool, group: "panel",
            summary: "Whether the main window opens in full screen.", fallback: .bool(false),
            scope: .standard),
        SettingDefinition(
            "hotKeyCode", .int, group: "panel",
            summary: "Virtual key code of the global panel shortcut.", fallback: .int(14)),
        SettingDefinition(
            "hotKeyMods", .int, group: "panel",
            summary: "Carbon modifier mask of the global panel shortcut.", fallback: .int(2304)),
        SettingDefinition(
            "hotKeyLabel", .string, group: "panel",
            summary: "Printable label for the global panel shortcut."),
        SettingDefinition(
            "tab", .string, group: "panel", summary: "Panel tab shown on open.",
            fallback: .string("usage"), scope: .standard),
        SettingDefinition(
            "tabOrder", .csv, group: "panel",
            summary: "Comma separated panel tab order."),
        SettingDefinition(
            "mainWindowSection", .string, group: "panel",
            summary: "Section the main window opens on."),
        SettingDefinition(
            "settingsTab", .string, group: "panel", summary: "Settings tab shown on open."),
        SettingDefinition(
            "mainSidebarOpen", .bool, group: "panel",
            summary: "Whether the main window sidebar starts open.", fallback: .bool(true)),
        SettingDefinition(
            "mainSidebarWidth", .number, group: "panel",
            summary: "Main window sidebar width in points."),
        SettingDefinition(
            "repoPath", .string, group: "panel",
            summary: "Development repository root used for usage data and music."),
    ]

    private static let usageAndLimits: [SettingDefinition] = [
        SettingDefinition(
            "tabUsageEnabled", .bool, group: "usage",
            summary: "Agent Usage extension: Claude and Codex limits, stats and alerts.",
            fallback: .bool(true)),
        SettingDefinition(
            "usageMachines", .stringList, group: "usage",
            summary: "Ids of the machines whose agent usage is collected over SSH."),
        SettingDefinition(
            "claudeLimitsEnabled", .bool, group: "limits",
            summary: "Track Claude rate limits.", fallback: .bool(true)),
        SettingDefinition(
            "codexLimitsEnabled", .bool, group: "limits",
            summary: "Track Codex rate limits.", fallback: .bool(true)),
        SettingDefinition(
            "limitsProvider", .string, group: "limits",
            summary: "Provider shown first in the limits UI.", allowed: ["claude", "codex"],
            fallback: .string("claude")),
        SettingDefinition(
            "warnPercent", .int, group: "limits",
            summary: "Percentage at which a limit turns amber.", fallback: .int(60)),
        SettingDefinition(
            "critPercent", .int, group: "limits",
            summary: "Percentage at which a limit turns red.", fallback: .int(85)),
        SettingDefinition(
            "pacingMargin", .number, group: "limits",
            summary: "Percentage points ahead of pace before pacing alerts fire.",
            fallback: .double(10)),
    ]

    private static let menuBar: [SettingDefinition] = [
        SettingDefinition(
            "limitsInMenuBar", .bool, group: "menubar",
            summary: "Show session and weekly percentages in the menu bar.",
            fallback: .bool(true)),
        SettingDefinition(
            "menuBarColorMode", .string, group: "menubar",
            summary: "How the menu bar readout is tinted.",
            allowed: ["auto", "white", "custom"], fallback: .string("auto")),
        SettingDefinition(
            "smartColor", .bool, group: "menubar",
            summary: "Tint the menu bar readout by a time-aware risk model."),
        SettingDefinition(
            "menuBarSubColorHex", .string, group: "menubar",
            summary: "Hex colour of the menu bar subtitle text."),
        SettingDefinition(
            "menuBarLowColorHex", .string, group: "menubar",
            summary: "Hex colour used below the warning threshold."),
        SettingDefinition(
            "menuBarMidColorHex", .string, group: "menubar",
            summary: "Hex colour used between the warning and critical thresholds."),
        SettingDefinition(
            "menuBarHighColorHex", .string, group: "menubar",
            summary: "Hex colour used above the critical threshold."),
        SettingDefinition(
            "menuBarStatsColorHex", .string, group: "menubar",
            summary: "Hex colour of the CPU and memory menu bar readout."),
        SettingDefinition(
            "menuBarSystemStats", .bool, group: "menubar",
            summary: "CPU and memory readout as a menu bar item.", fallback: .bool(false)),
    ]

    private static let alerts: [SettingDefinition] = [
        SettingDefinition(
            "notifSessionLevel", .int, group: "alerts",
            summary: "Session threshold the last alert fired at.", fallback: .int(0),
            scope: .standard, readOnly: true),
        SettingDefinition(
            "notifWeeklyLevel", .int, group: "alerts",
            summary: "Weekly threshold the last alert fired at.", fallback: .int(0),
            scope: .standard, readOnly: true),
        SettingDefinition(
            "notifSessionPacing", .string, group: "alerts",
            summary: "Session pacing zone the last alert fired for.", scope: .standard,
            readOnly: true),
        SettingDefinition(
            "notifWeeklyPacing", .string, group: "alerts",
            summary: "Weekly pacing zone the last alert fired for.", scope: .standard,
            readOnly: true),
        SettingDefinition(
            "notifyMaster", .bool, group: "alerts",
            summary: "Master switch for every usage notification.", fallback: .bool(false)),
        SettingDefinition(
            "notifyTrackSession", .bool, group: "alerts",
            summary: "Alert when the session limit crosses a threshold."),
        SettingDefinition(
            "notifyTrackWeekly", .bool, group: "alerts",
            summary: "Alert when the weekly limit crosses a threshold."),
        SettingDefinition(
            "notifyRecovery", .bool, group: "alerts",
            summary: "Alert when usage falls back into the green."),
        SettingDefinition(
            "notifyPacingWarning", .bool, group: "alerts",
            summary: "Alert when spend runs ahead of pace."),
        SettingDefinition(
            "notifyPacingHot", .bool, group: "alerts",
            summary: "Alert when spend is burning far ahead of pace."),
        SettingDefinition(
            "notifyReminderSession", .bool, group: "alerts",
            summary: "Remind before the session window resets."),
        SettingDefinition(
            "notifyReminderSessionOffsetMin", .int, group: "alerts",
            summary: "Minutes before the session reset to remind.", fallback: .int(15)),
        SettingDefinition(
            "notifyReminderWeekly", .bool, group: "alerts",
            summary: "Remind before the weekly window resets."),
        SettingDefinition(
            "notifyReminderWeeklyOffsetMin", .int, group: "alerts",
            summary: "Minutes before the weekly reset to remind.", fallback: .int(60)),
        SettingDefinition(
            "notifyTokenExpired", .bool, group: "alerts",
            summary: "Alert when a provider token expires."),
    ]

    private static let budget: [SettingDefinition] = [
        SettingDefinition(
            "budgetEnabled", .bool, group: "budget", summary: "Track a spend budget.",
            fallback: .bool(false)),
        SettingDefinition(
            "budgetMode", .string, group: "budget", summary: "Budget comparison mode.",
            allowed: BudgetMode.allCases.map(\.rawValue), fallback: .string("cap")),
        SettingDefinition(
            "budgetKind", .string, group: "budget", summary: "Window the budget applies to.",
            allowed: ["session", "weekly"], fallback: .string("session")),
        SettingDefinition(
            "budgetCapPercent", .number, group: "budget",
            summary: "Budget cap as a percentage of the limit.", fallback: .double(50)),
        SettingDefinition(
            "budgetDeadline", .number, group: "budget",
            summary: "Unix timestamp the budget is paced towards.", fallback: .double(0)),
    ]

    private static let dashboard: [SettingDefinition] = [
        SettingDefinition(
            "dashPaths", .string, group: "dashboard",
            summary: "Folder scope for the dashboard charts."),
        SettingDefinition(
            "dashRange", .string, group: "dashboard",
            summary: "Dashboard date range.", fallback: .string("all")),
        SettingDefinition(
            "dashSources", .csv, group: "dashboard",
            summary: "Comma separated usage sources included in the dashboard."),
        SettingDefinition(
            "dashKnownSources", .csv, group: "dashboard",
            summary: "Sources seen so far, used to auto-select newly discovered ones."),
        SettingDefinition(
            "dashSourceSelectionVersion", .int, group: "dashboard",
            summary: "Schema version of the stored source selection."),
        SettingDefinition(
            "dashModels", .string, group: "dashboard",
            summary: "Model filter for the dashboard charts."),
        SettingDefinition(
            "dashBillingDay", .int, group: "dashboard",
            summary: "Day of month the billing cycle starts on.", fallback: .int(26)),
        SettingDefinition(
            "dashSort", .string, group: "dashboard", summary: "Model table sort column.",
            fallback: .string("cost")),
        SettingDefinition(
            "dashSortAsc", .bool, group: "dashboard",
            summary: "Sort the model table ascending.", fallback: .bool(false)),
        SettingDefinition(
            "dashHeatMetric", .string, group: "dashboard",
            summary: "Metric the activity heatmap colours by.", allowed: ["tokens", "cost"],
            fallback: .string("tokens")),
        SettingDefinition(
            "projSort", .string, group: "dashboard", summary: "Project drilldown sort column.",
            fallback: .string("cost")),
        SettingDefinition(
            "projSortAsc", .bool, group: "dashboard",
            summary: "Sort the project drilldown ascending.", fallback: .bool(false)),
    ]

    private static let companion: [SettingDefinition] = [
        SettingDefinition(
            "tabCompanionEnabled", .bool, group: "companion",
            summary: "Show the Companion page.", fallback: .bool(false)),
        SettingDefinition(
            "companionEndpoint", .string, group: "companion",
            summary: "Companion API base URL the app and CLI talk to.",
            fallback: .string("http://127.0.0.1:4820")),
        SettingDefinition(
            "companionTab", .string, group: "companion",
            summary: "Companion screen shown on open.",
            allowed: ["chat", "capture", "desk", "library", "mind", "setup", "settings"],
            fallback: .string("chat")),
    ]

    private static let machines: [SettingDefinition] = [
        SettingDefinition(
            "machinesTab", .string, group: "machines",
            summary: "Machine detail tab shown on open.",
            allowed: ["overview", "processes", "docker", "terminal", "tools"],
            fallback: .string("overview")),
        SettingDefinition(
            "machinesSelection", .string, group: "machines",
            summary: "Identifier of the machine the detail view opens on."),
        SettingDefinition(
            "machinesMode", .string, group: "machines",
            summary: "Machines page view shown on open.",
            allowed: ["fleet", "workspace", "machine"], fallback: .string("fleet")),
        SettingDefinition(
            "dockerLogWrap", .bool, group: "machines",
            summary: "Wrap long lines in the Docker log viewer.", fallback: .bool(true)),
        SettingDefinition(
            "dockerLogTimestamps", .bool, group: "machines",
            summary: "Show timestamps in the Docker log viewer.", fallback: .bool(false)),
        SettingDefinition(
            "dockerLogFontSize", .number, group: "machines",
            summary: "Text size in the Docker log viewer.", fallback: .double(11)),
        SettingDefinition(
            "tabMachinesEnabled", .bool, group: "machines",
            summary: "Machines extension: other computers over SSH.", fallback: .bool(false)),
        SettingDefinition(
            "machinesAutoConnect", .bool, group: "machines",
            summary: "Connect to machines automatically when the app starts."),
        SettingDefinition(
            "machinesNotifyDown", .bool, group: "machines",
            summary: "Notify when a machine stops responding."),
        SettingDefinition(
            "machinesNotifyDiskFull", .bool, group: "machines",
            summary: "Notify when a machine's disk crosses the threshold."),
        SettingDefinition(
            "machinesDiskThreshold", .number, group: "machines",
            summary: "Disk usage percentage that triggers the disk alert.", fallback: .double(90)),
    ]

    private static let finder: [SettingDefinition] = [
        SettingDefinition(
            "finderViewMode", .string, group: "finder", summary: "Remote file browser layout.",
            allowed: FileViewMode.allCases.map(\.rawValue), fallback: .string("list")),
        SettingDefinition(
            "finderSortKey", .string, group: "finder", summary: "Remote file browser sort column.",
            allowed: FileSortKey.allCases.map(\.rawValue), fallback: .string("name")),
        SettingDefinition(
            "finderSortAscending", .bool, group: "finder",
            summary: "Sort the remote file browser ascending.", fallback: .bool(true)),
        SettingDefinition(
            "finderShowHidden", .bool, group: "finder",
            summary: "Show dotfiles in the remote file browser.", fallback: .bool(false)),
        SettingDefinition(
            "finderIconSize", .number, group: "finder",
            summary: "Icon size in the remote file browser."),
    ]

    private static let system: [SettingDefinition] = [
        SettingDefinition(
            "SUEnableAutomaticChecks", .bool, group: "system",
            summary: "Check for updates on a schedule.", fallback: .bool(true), scope: .standard),
        SettingDefinition(
            "SUScheduledCheckInterval", .number, group: "system",
            summary: "Seconds between scheduled update checks.", fallback: .double(86_400),
            scope: .standard),
        SettingDefinition(
            "SUAutomaticallyUpdate", .bool, group: "system",
            summary: "Download and install updates automatically.", fallback: .bool(true),
            scope: .standard),
        SettingDefinition(
            "tabSystemEnabled", .bool, group: "system",
            summary: "System extension: running apps, prevent sleep and the cleaning lock.",
            fallback: .bool(true)),
        SettingDefinition(
            "preventSleep", .bool, group: "system",
            summary: "Keep the Mac awake (Keep Awake).", fallback: .bool(false)),
        SettingDefinition(
            "systemAppsSort", .string, group: "system", summary: "Running apps sort column.",
            fallback: .string("memory")),
        SettingDefinition(
            "systemAppsSortAsc", .bool, group: "system",
            summary: "Sort running apps ascending.", fallback: .bool(false)),
    ]

    private static let cleaner: [SettingDefinition] = [
        SettingDefinition(
            "cleanerSelectedDrives", .stringList, group: "cleaner",
            summary: "Volumes the disk cleaner scans."),
        SettingDefinition(
            "cleanerCustomFolders", .stringList, group: "cleaner",
            summary: "Extra folders added to the disk cleaner."),
        SettingDefinition(
            "cleanerCategoryDefaults", .map, group: "cleaner",
            summary: "Per-category cleaner defaults."),
        SettingDefinition(
            "cleanerSelectionOverrides", .map, group: "cleaner",
            summary: "Per-path cleaner selection overrides."),
    ]

    private static let music: [SettingDefinition] = [
        SettingDefinition(
            "musicFolderStale", .bool, group: "music",
            summary: "Whether the stored music folder has gone missing.", fallback: .bool(false),
            readOnly: true),
        SettingDefinition(
            "musicCrossfadeEnabled", .bool, group: "music",
            summary: "Fade between tracks when one ends.", fallback: .bool(true)),
        SettingDefinition(
            "musicCrossfadeSeconds", .number, group: "music",
            summary: "Seconds the crossfade between tracks lasts.", fallback: .double(2)),
        SettingDefinition(
            "musicLastTrack", .string, group: "music",
            summary: "Relative path of the track playback resumes from.", scope: .standard,
            readOnly: true),
        SettingDefinition(
            "musicLastPosition", .number, group: "music",
            summary: "Seconds into the track playback resumes from.", fallback: .double(0),
            scope: .standard, readOnly: true),
        SettingDefinition(
            "musicWasPlaying", .bool, group: "music",
            summary: "Whether playback was running when the app last quit.",
            fallback: .bool(false), scope: .standard, readOnly: true),
        SettingDefinition(
            "tabMusicEnabled", .bool, group: "music",
            summary: "Music extension: local library playback with media keys.",
            fallback: .bool(false)),
        SettingDefinition(
            "musicVolume", .number, group: "music", summary: "Player volume from 0 to 1.",
            fallback: .double(0.7), scope: .standard),
        SettingDefinition(
            "musicLooping", .bool, group: "music", summary: "Repeat the current track.",
            fallback: .bool(false), scope: .standard),
        SettingDefinition(
            "musicGridView", .bool, group: "music", summary: "Show the library as a grid.",
            fallback: .bool(false)),
        SettingDefinition(
            "musicFolderPath", .string, group: "music",
            summary: "Folder the music library plays from."),
        SettingDefinition(
            "musicShuffling", .bool, group: "music", summary: "Play the folder in a random order.",
            fallback: .bool(false), scope: .standard),
        SettingDefinition(
            "musicFavourites", .stringList, group: "music",
            summary: "Relative paths of favourited tracks."),
        SettingDefinition(
            "musicDownloadKind", .string, group: "music",
            summary: "Default format for downloads.", allowed: ["audio", "video"],
            fallback: .string("audio")),
        SettingDefinition(
            "musicBackup", .bool, group: "music",
            summary: "Include the music folder in the iCloud backup."),
    ]

    private static let calendar: [SettingDefinition] = [
        SettingDefinition(
            "tabCalendarEnabled", .bool, group: "calendar",
            summary: "Calendar extension: your schedule in the panel and the app.",
            fallback: .bool(false))
    ]

    private static let clipboard: [SettingDefinition] = [
        SettingDefinition(
            "clipboardEnabled", .bool, group: "clipboard",
            summary: "Clipboard extension: history with instant paste.", fallback: .bool(false)),
        SettingDefinition(
            "clipboardHotKeyCode", .int, group: "clipboard",
            summary: "Virtual key code of the clipboard panel shortcut."),
        SettingDefinition(
            "clipboardHotKeyMods", .int, group: "clipboard",
            summary: "Carbon modifier mask of the clipboard panel shortcut."),
        SettingDefinition(
            "clipboardHotKeyLabel", .string, group: "clipboard",
            summary: "Printable label for the clipboard panel shortcut."),
        SettingDefinition(
            "clipboardMaxItems", .int, group: "clipboard",
            summary: "Maximum entries kept in the clipboard history."),
        SettingDefinition(
            "clipboardMaxItemBytes", .int, group: "clipboard",
            summary: "Largest single clipboard entry kept, in bytes."),
        SettingDefinition(
            "clipboardMaxAgeDays", .int, group: "clipboard",
            summary: "Days a clipboard entry is kept before it is pruned."),
        SettingDefinition(
            "clipboardIgnoredApps", .csv, group: "clipboard",
            summary: "Comma separated bundle identifiers never captured."),
        SettingDefinition(
            "clipboardAutoPaste", .bool, group: "clipboard",
            summary: "Paste straight into the frontmost app on pick."),
        SettingDefinition(
            "clipboardPastePlainText", .bool, group: "clipboard",
            summary: "Strip formatting when pasting."),
        SettingDefinition(
            "clipboardCheckInterval", .number, group: "clipboard",
            summary: "Seconds between pasteboard polls.", fallback: .double(1)),
        SettingDefinition(
            "clipboardPopupAt", .string, group: "clipboard",
            summary: "Where the clipboard panel opens.",
            allowed: ClipboardPopupPosition.allCases.map(\.rawValue),
            fallback: .string("cursor")),
        SettingDefinition(
            "clipboardPinTo", .string, group: "clipboard",
            summary: "Which edge the clipboard panel grows from.", allowed: ["top", "bottom"],
            fallback: .string("top")),
        SettingDefinition(
            "clipboardShowFooter", .bool, group: "clipboard",
            summary: "Show the hint footer in the clipboard panel."),
        SettingDefinition(
            "clipboardSaveFiles", .bool, group: "clipboard", summary: "Capture copied files."),
        SettingDefinition(
            "clipboardSaveImages", .bool, group: "clipboard", summary: "Capture copied images."),
        SettingDefinition(
            "clipboardSaveText", .bool, group: "clipboard", summary: "Capture copied text."),
        SettingDefinition(
            "clipboardBackup", .bool, group: "clipboard",
            summary: "Include clipboard history in the iCloud backup."),
        SettingDefinition(
            "clipboardWindowPositionX", .number, group: "clipboard",
            summary: "Last clipboard panel x position."),
        SettingDefinition(
            "clipboardWindowPositionY", .number, group: "clipboard",
            summary: "Last clipboard panel y position."),
    ]

    private static let notch: [SettingDefinition] = [
        SettingDefinition(
            "notchShelfEnabled", .bool, group: "notch",
            summary: "Notch Shelf extension: file shelf, now playing, camera and alerts.",
            fallback: .bool(false)),
        SettingDefinition(
            "notchShelfOpenOnDrag", .bool, group: "notch",
            summary: "Open the shelf when a drag reaches the notch."),
        SettingDefinition(
            "notchShelfOpenOnHover", .bool, group: "notch",
            summary: "Open the shelf on hover."),
        SettingDefinition(
            "notchShelfRequireOption", .bool, group: "notch",
            summary: "Require Option held to open the shelf."),
        SettingDefinition(
            "notchShelfKeepDuration", .string, group: "notch",
            summary: "How long shelf items are kept."),
        SettingDefinition(
            "notchShelfRemoveAfterDragOut", .bool, group: "notch",
            summary: "Remove an item from the shelf after it is dragged out."),
        SettingDefinition(
            "notchShelfShowOnExternal", .bool, group: "notch",
            summary: "Show the shelf on external displays."),
        SettingDefinition(
            "notchShelfHaptics", .bool, group: "notch", summary: "Haptic feedback on the shelf."),
        SettingDefinition(
            "notchShelfShowMusic", .bool, group: "notch",
            summary: "Show now playing controls in the shelf."),
        SettingDefinition(
            "notchAlertsEnabled", .bool, group: "notch", summary: "Show alerts around the notch."),
        SettingDefinition(
            "notchAlertAudio", .bool, group: "notch", summary: "Alert on audio device changes."),
        SettingDefinition(
            "notchAlertPower", .bool, group: "notch", summary: "Alert on power source changes."),
        SettingDefinition(
            "notchAlertBattery", .bool, group: "notch", summary: "Alert on battery level changes."),
        SettingDefinition(
            "notchAlertBluetooth", .bool, group: "notch",
            summary: "Alert on Bluetooth connections."),
        SettingDefinition(
            "notchAudioMixerEnabled", .bool, group: "notch",
            summary: "Per-app audio mixer in the notch shelf."),
    ]

    private static let focusDim: [SettingDefinition] = [
        SettingDefinition(
            "focusDimActive", .bool, group: "focusdim",
            summary: "Focus dim on right now.", fallback: .bool(false)),
        SettingDefinition(
            "focusDimEnabled", .bool, group: "focusdim",
            summary: "Focus Dim extension: dim everything behind the active app.",
            fallback: .bool(false)),
        SettingDefinition(
            "focusDimIntensity", .number, group: "focusdim",
            summary: "Dim strength from 0 to 1.", fallback: .double(0.5)),
        SettingDefinition(
            "focusDimAnimationDuration", .number, group: "focusdim",
            summary: "Seconds the dim takes to fade."),
        SettingDefinition(
            "focusDimOtherDisplaysMode", .string, group: "focusdim",
            summary: "How other displays are treated.",
            allowed: FocusDimDisplayMode.allCases.map(\.rawValue),
            fallback: .string("perScreenFront")),
        SettingDefinition(
            "focusDimHotKeyCode", .int, group: "focusdim",
            summary: "Virtual key code of the focus dim shortcut."),
        SettingDefinition(
            "focusDimHotKeyMods", .int, group: "focusdim",
            summary: "Carbon modifier mask of the focus dim shortcut."),
        SettingDefinition(
            "focusDimHotKeyLabel", .string, group: "focusdim",
            summary: "Printable label for the focus dim shortcut."),
    ]

    private static let presenter: [SettingDefinition] = [
        SettingDefinition(
            "presenterAutoActive", .bool, group: "presenter",
            summary: "A share is being detected right now.", fallback: .bool(false),
            readOnly: true),
        SettingDefinition(
            "presenterAutoPaused", .bool, group: "presenter",
            summary: "Auto presenter mode is paused until the current share ends.",
            fallback: .bool(false), readOnly: true),
        SettingDefinition(
            "presenterAutoReason", .string, group: "presenter",
            summary: "Why auto presenter mode turned on.", readOnly: true),
        SettingDefinition(
            "presenterEnabled", .bool, group: "presenter",
            summary: "Presenter extension: blur sensitive numbers while sharing.",
            fallback: .bool(false)),
        SettingDefinition(
            "presenterMode", .bool, group: "presenter",
            summary: "Presenter mode on right now.", fallback: .bool(false)),
        SettingDefinition(
            "presenterAutoEnabled", .bool, group: "presenter",
            summary: "Turn presenter mode on automatically when a share is detected."),
        SettingDefinition(
            "presenterDetectRecording", .bool, group: "presenter",
            summary: "Treat screen recording as a share."),
        SettingDefinition(
            "presenterDetectScreenSharing", .bool, group: "presenter",
            summary: "Treat screen sharing as a share."),
        SettingDefinition(
            "presenterDetectMirroring", .bool, group: "presenter",
            summary: "Treat display mirroring as a share."),
        SettingDefinition(
            "presenterHideMenuBarNumbers", .bool, group: "presenter",
            summary: "Hide menu bar percentages while presenting."),
        SettingDefinition(
            "presenterBlurMoney", .bool, group: "presenter", summary: "Blur spend figures."),
        SettingDefinition(
            "presenterBlurUsage", .bool, group: "presenter", summary: "Blur usage percentages."),
        SettingDefinition(
            "presenterBlurMusic", .bool, group: "presenter", summary: "Blur track names."),
        SettingDefinition(
            "presenterBlurCalendar", .bool, group: "presenter", summary: "Blur calendar entries."),
        SettingDefinition(
            "presenterHotKeyCode", .int, group: "presenter",
            summary: "Virtual key code of the presenter shortcut."),
        SettingDefinition(
            "presenterHotKeyMods", .int, group: "presenter",
            summary: "Carbon modifier mask of the presenter shortcut."),
        SettingDefinition(
            "presenterHotKeyLabel", .string, group: "presenter",
            summary: "Printable label for the presenter shortcut."),
    ]

    private static let colorPicker: [SettingDefinition] = [
        SettingDefinition(
            "colorPickerEnabled", .bool, group: "colorpicker",
            summary: "Color Picker extension: system loupe on a hotkey.", fallback: .bool(false)),
        SettingDefinition(
            "colorPickerCopyFormat", .string, group: "colorpicker",
            summary: "Format the sampled colour is copied in.",
            allowed: ColorCopyFormat.allCases.map(\.rawValue), fallback: .string("hex")),
        SettingDefinition(
            "colorPickerProfile", .string, group: "colorpicker",
            summary: "Colour space the loupe samples in.",
            allowed: ColorProfile.allCases.map(\.rawValue), fallback: .string("sRGB")),
        SettingDefinition(
            "colorPickerHistorySize", .int, group: "colorpicker",
            summary: "Number of swatches kept in the history."),
        SettingDefinition(
            "colorPickerHotKeyCode", .int, group: "colorpicker",
            summary: "Virtual key code of the colour picker shortcut."),
        SettingDefinition(
            "colorPickerHotKeyMods", .int, group: "colorpicker",
            summary: "Carbon modifier mask of the colour picker shortcut."),
        SettingDefinition(
            "colorPickerHotKeyLabel", .string, group: "colorpicker",
            summary: "Printable label for the colour picker shortcut."),
    ]

    private static let micMute: [SettingDefinition] = [
        SettingDefinition(
            "micMuted", .bool, group: "micmute", summary: "Microphone muted right now.",
            fallback: .bool(false), readOnly: true),
        SettingDefinition(
            "micMuteEnabled", .bool, group: "micmute",
            summary: "Mic Mute extension: system-wide microphone kill switch.",
            fallback: .bool(false)),
        SettingDefinition(
            "micMuteInMenuBar", .bool, group: "micmute",
            summary: "Show the mic mute indicator in the menu bar."),
        SettingDefinition(
            "micHotKeyCode", .int, group: "micmute",
            summary: "Virtual key code of the mic mute shortcut."),
        SettingDefinition(
            "micHotKeyMods", .int, group: "micmute",
            summary: "Carbon modifier mask of the mic mute shortcut."),
        SettingDefinition(
            "micHotKeyLabel", .string, group: "micmute",
            summary: "Printable label for the mic mute shortcut."),
    ]

    private static let terminal: [SettingDefinition] = [
        SettingDefinition(
            CompletionScripts.autoRefreshKey, .bool, group: "terminal",
            summary: "Keep the shell completion scripts current when the app starts.",
            fallback: .bool(true))
    ]

    private static let backup: [SettingDefinition] = [
        SettingDefinition(
            "icloudBackup", .bool, group: "backup",
            summary: "Master switch for the iCloud backup.", fallback: .bool(true)),
        SettingDefinition(
            "backupSettings", .bool, group: "backup", summary: "Back up settings to iCloud."),
        SettingDefinition(
            "backupUsage", .bool, group: "backup", summary: "Back up usage history to iCloud."),
        SettingDefinition(
            "backupLimits", .bool, group: "backup", summary: "Back up limit history to iCloud."),
        SettingDefinition(
            "lastBackupAt", .number, group: "backup",
            summary: "Unix timestamp of the last settings backup.", readOnly: true),
        SettingDefinition(
            "lastMusicBackupAt", .number, group: "backup",
            summary: "Unix timestamp of the last music backup.", readOnly: true),
        SettingDefinition(
            "lastClipboardBackupAt", .number, group: "backup",
            summary: "Unix timestamp of the last clipboard backup.", readOnly: true),
    ]

    private static let permissions: [SettingDefinition] =
        ExtensionPermission.allCases.compactMap { permission in
            guard let key = permission.grantedDefaultsKey else { return nil }
            return SettingDefinition(
                key, .bool, group: "permissions",
                summary: "\(permission.displayName) permission, as last observed by Edith.",
                fallback: .bool(false), readOnly: true)
        }
        + [
            SettingDefinition(
                "permissionsFilter", .string, group: "permissions",
                summary: "Filter the Permissions page opens with.")
        ]
}
