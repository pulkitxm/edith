import Foundation

public enum ExtensionMarketplaceCategory: String, CaseIterable, Hashable, Sendable {
    case all = "All"
    case agents = "Agents"
    case maintenance = "Maintenance"
    case system = "System"
    case desk = "Desk"
    case media = "Media"
    case data = "Data"

    public var suite: SuiteID? {
        switch self {
        case .all: nil
        case .agents: .agents
        case .maintenance: .maintenance
        case .system: .system
        case .desk: .desk
        case .media: .media
        case .data: .data
        }
    }

    public init(suite: SuiteID) {
        self =
            switch suite {
            case .agents: .agents
            case .maintenance: .maintenance
            case .system: .system
            case .desk: .desk
            case .media: .media
            case .data: .data
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
            let matchesCategory =
                !trimmedQuery.isEmpty || category.suite == nil || entry.suite == category.suite
            let matchesQuery =
                trimmedQuery.isEmpty || entry.title.localizedCaseInsensitiveContains(trimmedQuery)
                || entry.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
            return matchesCategory && matchesQuery
        }
    }

    public static func emptyState(
        query: String, category: ExtensionMarketplaceCategory
    ) -> (title: String, detail: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            return (
                "No abilities found",
                "No ability matches \"\(trimmedQuery)\". Try another search."
            )
        }
        if category == .all {
            return ("No abilities available", "No abilities are registered yet.")
        }
        return (
            "No \(category.rawValue) abilities",
            "This suite has no abilities available."
        )
    }
}

public struct ExtensionRegistryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let suite: SuiteID
    public let host: AbilityHost
    public let featured: Bool
    public let defaultsKey: String
    public let requires: [String]
    public let requiredCapabilities: [PlatformCapability]
    public let optionalCapabilities: [PlatformCapability]
    public let requiredToolIDs: [String]
    public let optionalToolIDs: [String]

    public init(
        id: String, title: String, subtitle: String, symbolName: String,
        suite: SuiteID, host: AbilityHost, featured: Bool, defaultsKey: String,
        requires: [String] = [],
        requiredCapabilities: [PlatformCapability],
        optionalCapabilities: [PlatformCapability] = [], requiredToolIDs: [String] = [],
        optionalToolIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.suite = suite
        self.host = host
        self.featured = featured
        self.defaultsKey = defaultsKey
        self.requires = requires
        self.requiredCapabilities = requiredCapabilities
        self.optionalCapabilities = optionalCapabilities
        self.requiredToolIDs = requiredToolIDs
        self.optionalToolIDs = optionalToolIDs
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
            id: "usage", title: "Usage",
            subtitle: "Claude and Codex limits, usage stats, and alerts.",
            symbolName: "chart.bar.fill", suite: .agents, host: .agent, featured: true,
            defaultsKey: "tabUsageEnabled", requiredCapabilities: [.usageCollection],
            optionalCapabilities: [.notifications], requiredToolIDs: ["claude", "codex"]),
        ExtensionRegistryEntry(
            id: "herdr", title: "Sessions",
            subtitle: "Live Herdr sessions on this Mac and your SSH machines.",
            symbolName: "rectangle.split.3x1.fill", suite: .agents, host: .agent, featured: true,
            defaultsKey: "tabHerdrEnabled", requiredCapabilities: [.herdrSessions]),
        ExtensionRegistryEntry(
            id: "quinjet", title: "Review",
            subtitle: "Review pull requests and live workspace changes in a native terminal.",
            symbolName: "arrow.triangle.branch", suite: .agents, host: .window, featured: true,
            defaultsKey: "tabQuinjetEnabled", requires: ["herdr"],
            requiredCapabilities: [.localTerminal], requiredToolIDs: ["quinjet"]),
        ExtensionRegistryEntry(
            id: "companion", title: "Memory",
            subtitle: "Your notes, voice memos and activity, remembered and searchable.",
            symbolName: "brain.head.profile", suite: .agents, host: .agent, featured: false,
            defaultsKey: "tabCompanionEnabled", requiredCapabilities: [.companionService]),
        ExtensionRegistryEntry(
            id: "appMaintenance", title: "Updates",
            subtitle: "Verified app installs, updates, review-first removal and history.",
            symbolName: "shippingbox.and.arrow.backward", suite: .maintenance, host: .agent,
            featured: true, defaultsKey: "appMaintenanceEnabled",
            requiredCapabilities: [.runningApplications],
            optionalCapabilities: [.packageManagement], optionalToolIDs: ["homebrew"]),
        ExtensionRegistryEntry(
            id: "homebrew", title: "Packages",
            subtitle: "One Homebrew client for formulae, casks and taps.",
            symbolName: "cube.box", suite: .maintenance, host: .agent, featured: false,
            defaultsKey: "homebrewEnabled", requires: ["appMaintenance"],
            requiredCapabilities: [.packageManagement], requiredToolIDs: ["homebrew"]),
        ExtensionRegistryEntry(
            id: "cleaner", title: "Cleaner",
            subtitle: "Find reclaimable space across your drives and remove it on review.",
            symbolName: "sparkles.rectangle.stack", suite: .maintenance, host: .agent,
            featured: false, defaultsKey: "cleanerEnabled",
            requiredCapabilities: [.diskCleaning]),
        ExtensionRegistryEntry(
            id: "system", title: "System",
            subtitle: "Running apps, prevent sleep, and the keyboard-cleaning lock.",
            symbolName: "switch.2", suite: .system, host: .bar, featured: true,
            defaultsKey: "tabSystemEnabled", requiredCapabilities: [.runningApplications],
            optionalCapabilities: [.preventSleep, .inputSuppression]),
        ExtensionRegistryEntry(
            id: "lidAwake", title: "Lid Awake",
            subtitle: "Keeps this Mac running with the lid shut, on battery and unplugged.",
            symbolName: "laptopcomputer", suite: .system, host: .bar, featured: false,
            defaultsKey: "lidAwakeEnabled", requiredCapabilities: [.preventSleep]),
        ExtensionRegistryEntry(
            id: "systemStats", title: "CPU & Memory in menu bar",
            subtitle: "Live CPU and memory readout as a menu bar item.",
            symbolName: "gauge.with.needle", suite: .system, host: .bar, featured: false,
            defaultsKey: "menuBarSystemStats", requiredCapabilities: [.systemMetrics]),
        ExtensionRegistryEntry(
            id: "micMute", title: "Mic Mute",
            subtitle: "Mute every microphone system-wide with ⌘⇧M or the menu bar icon.",
            symbolName: "mic.slash.fill", suite: .system, host: .bar, featured: false,
            defaultsKey: "micMuteEnabled", requiredCapabilities: [.microphoneControl],
            optionalCapabilities: [.globalShortcuts]),
        ExtensionRegistryEntry(
            id: "clipboard", title: "Clipboard",
            subtitle: "Clipboard history with instant paste.",
            symbolName: "doc.on.clipboard", suite: .desk, host: .bar, featured: true,
            defaultsKey: "clipboardEnabled", requiredCapabilities: [.clipboardHistory],
            optionalCapabilities: [.globalPaste, .globalShortcuts]),
        ExtensionRegistryEntry(
            id: "emoji", title: "Emoji Picker",
            subtitle: "Every macOS emoji on a hotkey, straight into the app you are typing in.",
            symbolName: "face.smiling", suite: .desk, host: .bar, featured: false,
            defaultsKey: "emojiEnabled", requiredCapabilities: [.emojiInsertion],
            optionalCapabilities: [.globalShortcuts]),
        ExtensionRegistryEntry(
            id: "colorPicker", title: "Color Picker",
            subtitle: "System loupe on a hotkey, sampled color to your clipboard.",
            symbolName: "eyedropper", suite: .desk, host: .bar, featured: false,
            defaultsKey: "colorPickerEnabled", requiredCapabilities: [.screenColorSampling],
            optionalCapabilities: [.globalShortcuts]),
        ExtensionRegistryEntry(
            id: "keystrokeHighlight", title: "Keystroke Highlight",
            subtitle: "Show each key press on screen for polished demos.",
            symbolName: "keyboard.badge.ellipsis", suite: .desk, host: .bar, featured: true,
            defaultsKey: "keystrokeHighlightEnabled",
            requiredCapabilities: [.keystrokeObservation]),
        ExtensionRegistryEntry(
            id: "focusDim", title: "Focus Dim",
            subtitle: "Dims everything behind your active app.",
            symbolName: "circle.lefthalf.filled", suite: .desk, host: .bar, featured: false,
            defaultsKey: "focusDimEnabled", requiredCapabilities: [.windowDimming]),
        ExtensionRegistryEntry(
            id: "presenter", title: "Presenter",
            subtitle: "Blurs sensitive numbers while sharing your screen.",
            symbolName: "theatermasks.fill", suite: .desk, host: .bar, featured: false,
            defaultsKey: "presenterEnabled", requiredCapabilities: [.screenShareDetection]),
        ExtensionRegistryEntry(
            id: "music", title: "Music",
            subtitle: "Plays your local music folder, with media keys and a player bar.",
            symbolName: "music.note", suite: .media, host: .bar, featured: false,
            defaultsKey: "tabMusicEnabled", requiredCapabilities: [.localMusicPlayback],
            optionalCapabilities: [.mediaControls]),
        ExtensionRegistryEntry(
            id: "downloads", title: "Downloads",
            subtitle: "Queue audio and video downloads that survive quitting the app.",
            symbolName: "arrow.down.circle", suite: .media, host: .agent, featured: false,
            defaultsKey: "downloadsEnabled", requires: ["music"],
            requiredCapabilities: [.mediaDownloads], requiredToolIDs: ["yt-dlp"]),
        ExtensionRegistryEntry(
            id: "notchShelf", title: "Notch Shelf",
            subtitle: "File shelf, now playing, camera, and alerts around the notch.",
            symbolName: "tray.and.arrow.down", suite: .media, host: .bar, featured: true,
            defaultsKey: "notchShelfEnabled", requiredCapabilities: [.fileShelf],
            optionalCapabilities: [
                .bluetoothMonitoring, .cameraPreview, .externalMediaControl,
            ]),
        ExtensionRegistryEntry(
            id: "audioMixer", title: "Audio Mixer",
            subtitle: "Per-app volume from the notch shelf.",
            symbolName: "slider.horizontal.3", suite: .media, host: .bar, featured: false,
            defaultsKey: "notchAudioMixerEnabled", requires: ["notchShelf"],
            requiredCapabilities: [.applicationAudio]),
        ExtensionRegistryEntry(
            id: "calendar", title: "Calendar",
            subtitle: "Shows your schedule in the panel and the app.",
            symbolName: "calendar", suite: .media, host: .bar, featured: false,
            defaultsKey: "tabCalendarEnabled", requiredCapabilities: [.calendarEvents]),
        ExtensionRegistryEntry(
            id: "database", title: "Database",
            subtitle: "Explore databases and run guarded production mutations.",
            symbolName: "cylinder.fill", suite: .data, host: .agent, featured: true,
            defaultsKey: "tabDatabaseEnabled", requiredCapabilities: [.databaseBroker]),
        ExtensionRegistryEntry(
            id: "attention", title: "Attention",
            subtitle: "Understand where your time goes and protect focused work!",
            symbolName: "hourglass", suite: .data, host: .bar, featured: true,
            defaultsKey: "tabAttentionEnabled", requiredCapabilities: [.runningApplications]),
        ExtensionRegistryEntry(
            id: "seoAudit", title: "Site Audit",
            subtitle: "Crawl sitemaps, inspect page metadata, and keep every run local.",
            symbolName: "doc.text.magnifyingglass", suite: .data, host: .agent, featured: false,
            defaultsKey: "tabSEOAuditEnabled", requiredCapabilities: [.siteAuditing]),
    ]

    public static func entry(_ id: String) -> ExtensionRegistryEntry? {
        entries.first { $0.id == id }
    }
}
