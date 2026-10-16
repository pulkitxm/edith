import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct SettingDefinition: Equatable, Sendable {
    enum ValueType: String, Equatable, Sendable {
        case bool
        case int
        case number
        case string
        case csv
        case stringList
        case map
    }

    enum Scope: String, Equatable, Sendable {
        case shared
        case standard
    }

    let key: String
    let type: ValueType
    let scope: Scope
    let group: String
    let summary: String
    let allowed: [String]
    let integerRange: ClosedRange<Int>?
    let fallback: JSONValue
    let readOnly: Bool

    init(
        _ key: String, _ type: ValueType, group: String, summary: String,
        allowed: [String] = [], integerRange: ClosedRange<Int>? = nil,
        fallback: JSONValue = .null, scope: Scope = .shared, readOnly: Bool = false
    ) {
        self.key = key
        self.type = type
        self.scope = scope
        self.group = group
        self.summary = summary
        self.allowed = allowed
        self.integerRange = integerRange
        self.fallback = fallback
        self.readOnly = readOnly
    }
}

enum ConfigCatalog {
    static let groups = ["machines", "finder"]
    static let settings = machines + finder
    static var keys: [String] { settings.map(\.key) }

    static func definition(for key: String) -> SettingDefinition? {
        settings.first { $0.key == key }
    }

    static func matching(prefix: String) -> [SettingDefinition] {
        guard !prefix.isEmpty else { return settings }
        return settings.filter { $0.key.hasPrefix(prefix) }
    }

    static func inGroup(_ group: String) -> [SettingDefinition] {
        settings.filter { $0.group == group }
    }

    private static let machines: [SettingDefinition] = [
        SettingDefinition(
            AppStorageKeys.Machines.tab, .string, group: "machines",
            summary: "Machine detail tab shown on open.",
            allowed: ["overview", "processes", "docker", "terminal", "tools"],
            fallback: .string("overview")),
        SettingDefinition(
            AppStorageKeys.Machines.selection, .string, group: "machines",
            summary: "Identifier of the machine the detail view opens on."),
        SettingDefinition(
            AppStorageKeys.Machines.mode, .string, group: "machines",
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
            AppStorageKeys.Machines.autoConnect, .bool, group: "machines",
            summary: "Connect to machines automatically when the app starts."),
        SettingDefinition(
            AppStorageKeys.Machines.notifyDown, .bool, group: "machines",
            summary: "Notify when a machine stops responding."),
        SettingDefinition(
            AppStorageKeys.Machines.notifyDiskFull, .bool, group: "machines",
            summary: "Notify when a machine's disk crosses the threshold."),
        SettingDefinition(
            AppStorageKeys.Machines.diskThreshold, .number, group: "machines",
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

}
