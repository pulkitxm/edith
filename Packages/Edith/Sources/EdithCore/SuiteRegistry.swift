import Foundation

public enum SuiteID: String, CaseIterable, Codable, Hashable, Sendable {
    case agents
    case maintenance
    case system
    case desk
    case media
    case data
}

public enum AbilityHost: String, CaseIterable, Codable, Hashable, Sendable {
    case agent
    case bar
    case window

    public var title: String {
        switch self {
        case .agent: "Background agent"
        case .bar: "Menu bar"
        case .window: "Window"
        }
    }

    public var summary: String {
        switch self {
        case .agent: "Runs in edithd with no window and no permission prompt."
        case .bar: "Runs in the menu bar app because it needs a session or a grant."
        case .window: "Runs in the Edith window while the page is open."
        }
    }
}

public struct SuiteDescriptor: Identifiable, Equatable, Sendable {
    public let id: SuiteID
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let defaultsKey: String
    public let toolIDs: [String]
    public let requiresFleet: Bool

    public init(
        id: SuiteID, title: String, subtitle: String, symbolName: String, defaultsKey: String,
        toolIDs: [String] = [], requiresFleet: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.defaultsKey = defaultsKey
        self.toolIDs = toolIDs
        self.requiresFleet = requiresFleet
    }
}

public enum SuiteRegistry {
    public static let suites: [SuiteDescriptor] = [
        SuiteDescriptor(
            id: .agents, title: "Agents",
            subtitle: "Usage, live sessions, review and memory for your coding agents.",
            symbolName: "sparkles", defaultsKey: "suiteAgentsEnabled",
            toolIDs: ["claude", "codex", "quinjet"], requiresFleet: true),
        SuiteDescriptor(
            id: .maintenance, title: "Maintenance",
            subtitle: "Updates, packages, review-first removal, disk cleanup and history.",
            symbolName: "shippingbox.and.arrow.backward",
            defaultsKey: "suiteMaintenanceEnabled", toolIDs: ["homebrew", "mas"]),
        SuiteDescriptor(
            id: .system, title: "System",
            subtitle: "Running apps, sleep, the cleaning lock, menu bar stats and mic mute.",
            symbolName: "switch.2", defaultsKey: "suiteSystemEnabled"),
        SuiteDescriptor(
            id: .desk, title: "Desk",
            subtitle: "Clipboard, emoji and color pickers, keystrokes, dimming and presenting.",
            symbolName: "hand.tap", defaultsKey: "suiteDeskEnabled"),
        SuiteDescriptor(
            id: .media, title: "Media",
            subtitle: "Music, downloads, the notch shelf, the audio mixer and your calendar.",
            symbolName: "play.rectangle.on.rectangle", defaultsKey: "suiteMediaEnabled"),
        SuiteDescriptor(
            id: .data, title: "Data",
            subtitle: "Databases, attention history and local site audits.",
            symbolName: "cylinder.split.1x2", defaultsKey: "suiteDataEnabled"),
    ]

    public static func suite(_ id: SuiteID) -> SuiteDescriptor {
        suites.first { $0.id == id }!
    }

    public static func abilities(in suite: SuiteID) -> [ExtensionRegistryEntry] {
        ExtensionRegistry.entries.filter { $0.suite == suite }
    }

    public static var defaultsKeys: [String] { suites.map(\.defaultsKey) }

    public static func isEnabled(_ suite: SuiteID, in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: SuiteRegistry.suite(suite).defaultsKey)
    }
}
