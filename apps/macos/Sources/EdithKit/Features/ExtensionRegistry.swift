import Foundation

public enum ExtensionPermission: String, CaseIterable, Hashable, Sendable {
    case calendar
    case notifications
    case accessibility
    case inputMonitoring
    case fullDisk
    case screenRecording
    case camera
    case bluetooth
    case automation

    public var displayName: String {
        switch self {
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .fullDisk: "Full Disk Access"
        case .screenRecording: "Screen Recording"
        case .camera: "Camera"
        case .bluetooth: "Bluetooth"
        case .automation: "Automation"
        }
    }

    public var reason: String {
        switch self {
        case .calendar: "Required to read and show your schedule in Calendar."
        case .notifications: "Asked when you enable usage limit, pacing, or reset alerts."
        case .accessibility:
            "Asked when you first use Clean keys or clipboard instant paste."
        case .inputMonitoring:
            "Asked when you first use Clean keys to block key presses during cleaning."
        case .fullDisk: "Asked when a feature needs local service credentials or usage data."
        case .screenRecording:
            "Required to detect shared content or sample colors from the screen."
        case .camera: "Asked when you first open the Notch Shelf camera preview."
        case .bluetooth: "Asked when Notch Shelf first checks for device connections."
        case .automation: "Asked when Notch Shelf first controls external playback."
        }
    }

    public var grantedDefaultsKey: String? {
        switch self {
        case .calendar: "permCalendarGranted"
        case .notifications: "permNotificationsGranted"
        case .accessibility: "permAccessibilityGranted"
        case .inputMonitoring: "permInputMonitoringGranted"
        case .fullDisk: "permFullDiskGranted"
        case .screenRecording: "permScreenRecordingGranted"
        case .camera: "permCameraGranted"
        case .bluetooth, .automation: nil
        }
    }

    public var symbolName: String {
        switch self {
        case .calendar: "calendar"
        case .notifications: "bell.badge"
        case .accessibility: "figure.wave"
        case .inputMonitoring: "keyboard"
        case .fullDisk: "externaldrive"
        case .screenRecording: "rectangle.inset.filled.badge.record"
        case .camera: "camera"
        case .bluetooth: "wave.3.right"
        case .automation: "gearshape.2"
        }
    }

    public var grantRequest: Notification.Name? {
        switch self {
        case .calendar: IPC.Name.grantCalendar
        case .notifications: IPC.Name.grantNotifications
        case .accessibility: IPC.Name.grantAccessibility
        case .inputMonitoring: IPC.Name.grantInputMonitoring
        case .fullDisk: IPC.Name.grantFullDisk
        case .screenRecording: IPC.Name.grantScreenRecording
        case .camera: IPC.Name.grantCamera
        case .bluetooth, .automation: nil
        }
    }

    public var firstUseExplanation: String? {
        switch self {
        case .bluetooth:
            "macOS will ask for Bluetooth access when connection alerts first run."
        case .automation:
            "macOS will ask for Automation access when Notch Shelf first controls playback."
        default: nil
        }
    }
}

public enum ExtensionEnableDecision: Equatable, Sendable {
    case enableDirectly
    case showSheet(required: [ExtensionPermission], optional: [ExtensionPermission])
}

public enum ExtensionPermissionFlow {
    public static func decision(
        for entry: ExtensionRegistryEntry, granted: [ExtensionPermission: Bool],
        hasSeenPermissions _: Bool
    ) -> ExtensionEnableDecision {
        let missingRequired = entry.requiredPermissions.filter { granted[$0] != true }
        let missingOptional = entry.optionalPermissions.filter { granted[$0] != true }
        if !missingRequired.isEmpty {
            return .showSheet(required: missingRequired, optional: missingOptional)
        }
        return .enableDirectly
    }
}

public enum ExtensionGroup: String, CaseIterable, Equatable, Sendable {
    case agent = "Agent"
    case system = "System"
    case media = "Media"
    case utilities = "Utilities"
}

public enum ExtensionMarketplaceCategory: String, CaseIterable, Hashable, Sendable {
    case all = "All"
    case agent = "Agent"
    case system = "System"
    case media = "Media"
    case utilities = "Utilities"

    public var group: ExtensionGroup? {
        switch self {
        case .all: nil
        case .agent: .agent
        case .system: .system
        case .media: .media
        case .utilities: .utilities
        }
    }
}

public enum ExtensionMarketplaceFilter {
    public static func filter(
        entries: [ExtensionRegistryEntry], query: String,
        category: ExtensionMarketplaceCategory
    ) -> [ExtensionRegistryEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesCategory = category.group == nil || entry.group == category.group
            let matchesQuery =
                trimmedQuery.isEmpty || entry.title.localizedCaseInsensitiveContains(trimmedQuery)
                || entry.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
            return matchesCategory && matchesQuery
        }
    }
}

public struct ExtensionRegistryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let group: ExtensionGroup
    public let featured: Bool
    public let defaultsKey: String
    public let requiredPermissions: [ExtensionPermission]
    public let optionalPermissions: [ExtensionPermission]
    public let requiredTools: [CLIToolSpec]

    public init(
        id: String, title: String, subtitle: String, symbolName: String,
        group: ExtensionGroup, featured: Bool, defaultsKey: String,
        requiredPermissions: [ExtensionPermission] = [],
        optionalPermissions: [ExtensionPermission] = [], requiredTools: [CLIToolSpec] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.group = group
        self.featured = featured
        self.defaultsKey = defaultsKey
        self.requiredPermissions = requiredPermissions
        self.optionalPermissions = optionalPermissions
        self.requiredTools = requiredTools
    }
}

public enum ExtensionRegistry {
    public static let entries: [ExtensionRegistryEntry] = [
        ExtensionRegistryEntry(
            id: "usage", title: "Agent Usage",
            subtitle: "Claude and Codex limits, usage stats, and alerts.",
            symbolName: "chart.bar.fill", group: .agent, featured: true,
            defaultsKey: "tabUsageEnabled", optionalPermissions: [.notifications],
            requiredTools: [.claudeCode, .codex]),
        ExtensionRegistryEntry(
            id: "system", title: "System",
            subtitle: "Running apps, prevent sleep, and the keyboard-cleaning lock.",
            symbolName: "switch.2", group: .system, featured: true,
            defaultsKey: "tabSystemEnabled",
            optionalPermissions: [.accessibility, .inputMonitoring]),
        ExtensionRegistryEntry(
            id: "machines", title: "Machines",
            subtitle: "Your other computers over SSH: stats, files, Docker, and a terminal.",
            symbolName: "server.rack", group: .system, featured: true,
            defaultsKey: "tabMachinesEnabled", optionalPermissions: [.notifications]),
        ExtensionRegistryEntry(
            id: "companion", title: "Companion",
            subtitle: "Your notes, voice memos and activity, remembered and searchable.",
            symbolName: "brain.head.profile", group: .agent, featured: false,
            defaultsKey: "tabCompanionEnabled"),
        ExtensionRegistryEntry(
            id: "systemStats", title: "CPU & Memory in menu bar",
            subtitle: "Live CPU and memory readout as a menu bar item.",
            symbolName: "gauge.with.needle", group: .system, featured: false,
            defaultsKey: "menuBarSystemStats"),
        ExtensionRegistryEntry(
            id: "micMute", title: "Mic Mute",
            subtitle: "Mute every microphone system-wide with ⌘⇧M or the menu bar icon.",
            symbolName: "mic.slash.fill", group: .system, featured: false,
            defaultsKey: "micMuteEnabled"),
        ExtensionRegistryEntry(
            id: "music", title: "Music",
            subtitle: "Plays your local music folder, with media keys.",
            symbolName: "music.note", group: .media, featured: false,
            defaultsKey: "tabMusicEnabled", requiredTools: [.youtubeDownloader]),
        ExtensionRegistryEntry(
            id: "calendar", title: "Calendar",
            subtitle: "Shows your schedule in the panel and the app.",
            symbolName: "calendar", group: .media, featured: false,
            defaultsKey: "tabCalendarEnabled", requiredPermissions: [.calendar]),
        ExtensionRegistryEntry(
            id: "notchShelf", title: "Notch Shelf",
            subtitle: "File shelf, now playing, camera, and alerts around the notch.",
            symbolName: "tray.and.arrow.down", group: .media, featured: true,
            defaultsKey: "notchShelfEnabled",
            optionalPermissions: [.bluetooth, .camera, .automation]),
        ExtensionRegistryEntry(
            id: "clipboard", title: "Clipboard",
            subtitle: "Clipboard history with instant paste.",
            symbolName: "doc.on.clipboard", group: .utilities, featured: true,
            defaultsKey: "clipboardEnabled", optionalPermissions: [.accessibility]),
        ExtensionRegistryEntry(
            id: "focusDim", title: "Focus Dim",
            subtitle: "Dims everything behind your active app.",
            symbolName: "circle.lefthalf.filled", group: .utilities, featured: false,
            defaultsKey: "focusDimEnabled", requiredPermissions: [.screenRecording]),
        ExtensionRegistryEntry(
            id: "presenter", title: "Presenter",
            subtitle: "Blurs sensitive numbers while sharing your screen.",
            symbolName: "theatermasks.fill", group: .utilities, featured: false,
            defaultsKey: "presenterEnabled", requiredPermissions: [.screenRecording]),
        ExtensionRegistryEntry(
            id: "colorPicker", title: "Color Picker",
            subtitle: "System loupe on a hotkey, sampled color to your clipboard.",
            symbolName: "eyedropper", group: .utilities, featured: false,
            defaultsKey: "colorPickerEnabled", requiredPermissions: [.screenRecording]),
    ]
}
