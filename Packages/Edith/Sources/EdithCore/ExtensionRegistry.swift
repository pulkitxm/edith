import Foundation

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
    public let requiredCapabilities: [PlatformCapability]
    public let optionalCapabilities: [PlatformCapability]
    public let requiredToolIDs: [String]

    public init(
        id: String, title: String, subtitle: String, symbolName: String,
        group: ExtensionGroup, featured: Bool, defaultsKey: String,
        requiredCapabilities: [PlatformCapability],
        optionalCapabilities: [PlatformCapability] = [], requiredToolIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.group = group
        self.featured = featured
        self.defaultsKey = defaultsKey
        self.requiredCapabilities = requiredCapabilities
        self.optionalCapabilities = optionalCapabilities
        self.requiredToolIDs = requiredToolIDs
    }

    public func availability(
        on platformCapabilities: PlatformCapabilities
    ) -> ExtensionPlatformAvailability {
        platformCapabilities.availability(
            required: requiredCapabilities, optional: optionalCapabilities)
    }
}

public enum ExtensionRegistry {
    public static let entries: [ExtensionRegistryEntry] = [
        ExtensionRegistryEntry(
            id: "usage", title: "Agent Usage",
            subtitle: "Claude and Codex limits, usage stats, and alerts.",
            symbolName: "chart.bar.fill", group: .agent, featured: true,
            defaultsKey: "tabUsageEnabled", requiredCapabilities: [.usageCollection],
            optionalCapabilities: [.notifications], requiredToolIDs: ["claude", "codex"]),
        ExtensionRegistryEntry(
            id: "herdr", title: "Herdr",
            subtitle: "Live Herdr sessions on this Mac and your SSH machines.",
            symbolName: "rectangle.split.3x1.fill", group: .agent, featured: true,
            defaultsKey: "tabHerdrEnabled", requiredCapabilities: [.herdrSessions]),
        ExtensionRegistryEntry(
            id: "system", title: "System",
            subtitle: "Running apps, prevent sleep, and the keyboard-cleaning lock.",
            symbolName: "switch.2", group: .system, featured: true,
            defaultsKey: "tabSystemEnabled", requiredCapabilities: [.runningApplications],
            optionalCapabilities: [.preventSleep, .inputSuppression]),
        ExtensionRegistryEntry(
            id: "machines", title: "Machines",
            subtitle: "Your other computers over SSH: stats, files, Docker, and a terminal.",
            symbolName: "server.rack", group: .system, featured: true,
            defaultsKey: "tabMachinesEnabled", requiredCapabilities: [.machineManagement],
            optionalCapabilities: [.notifications]),
        ExtensionRegistryEntry(
            id: "companion", title: "Companion",
            subtitle: "Your notes, voice memos and activity, remembered and searchable.",
            symbolName: "brain.head.profile", group: .agent, featured: false,
            defaultsKey: "tabCompanionEnabled", requiredCapabilities: [.companionService]),
        ExtensionRegistryEntry(
            id: "systemStats", title: "CPU & Memory in menu bar",
            subtitle: "Live CPU and memory readout as a menu bar item.",
            symbolName: "gauge.with.needle", group: .system, featured: false,
            defaultsKey: "menuBarSystemStats", requiredCapabilities: [.systemMetrics]),
        ExtensionRegistryEntry(
            id: "micMute", title: "Mic Mute",
            subtitle: "Mute every microphone system-wide with ⌘⇧M or the menu bar icon.",
            symbolName: "mic.slash.fill", group: .system, featured: false,
            defaultsKey: "micMuteEnabled", requiredCapabilities: [.microphoneControl],
            optionalCapabilities: [.globalShortcuts]),
        ExtensionRegistryEntry(
            id: "lidAwake", title: "Lid Awake",
            subtitle: "Keeps this Mac running with the lid shut, on battery and unplugged.",
            symbolName: "laptopcomputer", group: .system, featured: false,
            defaultsKey: "lidAwakeEnabled", requiredCapabilities: [.preventSleep]),
        ExtensionRegistryEntry(
            id: "music", title: "Music",
            subtitle: "Plays your local music folder, with media keys.",
            symbolName: "music.note", group: .media, featured: false,
            defaultsKey: "tabMusicEnabled", requiredCapabilities: [.localMusicPlayback],
            optionalCapabilities: [.mediaControls], requiredToolIDs: ["yt-dlp"]),
        ExtensionRegistryEntry(
            id: "calendar", title: "Calendar",
            subtitle: "Shows your schedule in the panel and the app.",
            symbolName: "calendar", group: .media, featured: false,
            defaultsKey: "tabCalendarEnabled", requiredCapabilities: [.calendarEvents]),
        ExtensionRegistryEntry(
            id: "notchShelf", title: "Notch Shelf",
            subtitle: "File shelf, now playing, camera, and alerts around the notch.",
            symbolName: "tray.and.arrow.down", group: .media, featured: true,
            defaultsKey: "notchShelfEnabled", requiredCapabilities: [.fileShelf],
            optionalCapabilities: [
                .bluetoothMonitoring, .cameraPreview, .externalMediaControl,
            ]),
        ExtensionRegistryEntry(
            id: "clipboard", title: "Clipboard",
            subtitle: "Clipboard history with instant paste.",
            symbolName: "doc.on.clipboard", group: .utilities, featured: true,
            defaultsKey: "clipboardEnabled", requiredCapabilities: [.clipboardHistory],
            optionalCapabilities: [.globalPaste, .globalShortcuts]),
        ExtensionRegistryEntry(
            id: "focusDim", title: "Focus Dim",
            subtitle: "Dims everything behind your active app.",
            symbolName: "circle.lefthalf.filled", group: .utilities, featured: false,
            defaultsKey: "focusDimEnabled", requiredCapabilities: [.windowDimming]),
        ExtensionRegistryEntry(
            id: "presenter", title: "Presenter",
            subtitle: "Blurs sensitive numbers while sharing your screen.",
            symbolName: "theatermasks.fill", group: .utilities, featured: false,
            defaultsKey: "presenterEnabled", requiredCapabilities: [.screenShareDetection]),
        ExtensionRegistryEntry(
            id: "colorPicker", title: "Color Picker",
            subtitle: "System loupe on a hotkey, sampled color to your clipboard.",
            symbolName: "eyedropper", group: .utilities, featured: false,
            defaultsKey: "colorPickerEnabled", requiredCapabilities: [.screenColorSampling],
            optionalCapabilities: [.globalShortcuts]),
    ]
}
