import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
struct UsageSettingDefinition: Equatable, Sendable {
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

enum UsageConfigCatalog {
    static let settings = (usageAndLimits + menuBar + alerts + budget + dashboard).filter {
        UsageUIPreferences.editableKeys.contains($0.key)
            || $0.key == UsageMachinesPeer.selectedDefaultsKey
    }
    static var keys: [String] { settings.map(\.key) }
    static var groups: [String] { Array(Set(settings.map(\.group))).sorted() }
    static func definition(for key: String) -> UsageSettingDefinition? {
        settings.first { $0.key == key }
    }
    static func matching(prefix: String) -> [UsageSettingDefinition] {
        settings.filter { $0.key.hasPrefix(prefix) }
    }
    private static let usageAndLimits: [UsageSettingDefinition] = [
        UsageSettingDefinition(
            AppStorageKeys.Tabs.usageEnabled, .bool, group: "usage",
            summary:
                "Agent Usage extension: Claude, Codex, Cursor and Grok limits, stats and alerts.",
            fallback: .bool(false)),
        UsageSettingDefinition(
            "usageMachines", .stringList, group: "usage",
            summary: "Ids of the machines whose agent usage is collected over SSH."),
        UsageSettingDefinition(
            AppStorageKeys.Limits.claudeEnabled, .bool, group: "limits",
            summary: "Track Claude rate limits.", fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Limits.codexEnabled, .bool, group: "limits",
            summary: "Track Codex rate limits.", fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Limits.cursorEnabled, .bool, group: "limits",
            summary: "Track Cursor models and other models included usage.", fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Limits.grokEnabled, .bool, group: "limits",
            summary: "Track the Grok weekly or monthly allowance.", fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Limits.provider, .string, group: "limits",
            summary: "Provider shown first in the limits UI.",
            allowed: ["claude", "codex", "cursor", "grok"],
            fallback: .string("claude")),
        UsageSettingDefinition(
            AppStorageKeys.Limits.warnPercent, .int, group: "limits",
            summary: "Percentage at which a limit turns amber.", fallback: .int(60)),
        UsageSettingDefinition(
            AppStorageKeys.Limits.critPercent, .int, group: "limits",
            summary: "Percentage at which a limit turns red.", fallback: .int(85)),
        UsageSettingDefinition(
            AppStorageKeys.Limits.pacingMargin, .number, group: "limits",
            summary: "Percentage points ahead of an even pace before smart color turns amber.",
            fallback: .double(10)),
    ]

    private static let menuBar: [UsageSettingDefinition] = [
        UsageSettingDefinition(
            AppStorageKeys.Limits.inMenuBar, .bool, group: "menubar",
            summary: "Show limit percentages in the menu bar.",
            fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.claudeWindows, .string, group: "menubar",
            summary: "Claude windows shown in the menu bar, comma-separated"
                + " (session, week, fable).",
            fallback: .string("session,week,fable")),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.codexWindows, .string, group: "menubar",
            summary: "Codex windows shown in the menu bar, comma-separated (session, week).",
            fallback: .string("session,week")),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.cursorWindows, .string, group: "menubar",
            summary: "Cursor pools shown in the menu bar, comma-separated (session, week)."
                + " session is Cursor models and week is Other models.",
            fallback: .string("session,week")),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.grokWindows, .string, group: "menubar",
            summary: "Grok allowance shown in the menu bar. week is the plan pool.",
            fallback: .string("week")),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.limitsStyle, .string, group: "menubar",
            summary: "Layout of the menu bar limits readout.",
            allowed: ["stacked", "tagged", "slash"], fallback: .string("stacked")),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.colorMode, .string, group: "menubar",
            summary: "How the menu bar readout is tinted.",
            allowed: ["auto", "custom"], fallback: .string("auto")),
        UsageSettingDefinition(
            AppStorageKeys.General.smartColor, .bool, group: "menubar",
            summary: "Tint the menu bar readout by a time-aware risk model."),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.subColorHex, .string, group: "menubar",
            summary: "Hex colour of the menu bar subtitle text."),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.lowColorHex, .string, group: "menubar",
            summary: "Hex colour used below the warning threshold."),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.midColorHex, .string, group: "menubar",
            summary: "Hex colour used between the warning and critical thresholds."),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.highColorHex, .string, group: "menubar",
            summary: "Hex colour used above the critical threshold."),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.statsColorHex, .string, group: "menubar",
            summary: "Hex colour of the CPU and memory menu bar readout."),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.statsColorMode, .string, group: "menubar",
            summary: "How the CPU and memory menu bar readout is tinted.",
            allowed: ["auto", "custom"], fallback: .string("auto")),
        UsageSettingDefinition(
            AppStorageKeys.MenuBar.systemStats, .bool, group: "menubar",
            summary: "CPU and memory readout as a menu bar item.", fallback: .bool(false)),
    ]

    private static let alerts: [UsageSettingDefinition] = [
        UsageSettingDefinition(
            AppStorageKeys.Notify.master, .bool, group: "alerts",
            summary: "Master switch for every usage notification.", fallback: .bool(false)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.trackSession, .bool, group: "alerts",
            summary: "Send limit alerts for 5-hour windows.", fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.trackWeekly, .bool, group: "alerts",
            summary:
                "Send limit alerts for weekly windows, Fable included, and Cursor's billing-cycle pools.",
            fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.onPace, .bool, group: "alerts",
            summary: "Alert when the recent burn rate would hit the cap before the reset.",
            fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.almostCapped, .bool, group: "alerts",
            summary: "Alert once per window when usage crosses the almost-capped line.",
            fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.almostCappedPercent, .int, group: "alerts",
            summary: "Percentage that counts as almost capped.",
            integerRange: LimitAlertSettings.almostCappedRange,
            fallback: .int(LimitAlertSettings.defaultAlmostCappedPercent)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.capped, .bool, group: "alerts",
            summary: "Alert when a window hits 100%, with its reset time.", fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.back, .bool, group: "alerts",
            summary: "Alert at the reset of a window that was capped or nearly capped.",
            fallback: .bool(true)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.outlook, .bool, group: "alerts",
            summary: "Morning outlook when a weekly window is heading for a tight finish.",
            fallback: .bool(false)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.headroom, .bool, group: "alerts",
            summary: "Alert on the last day of a weekly window when half or more is unused.",
            fallback: .bool(false)),
        UsageSettingDefinition(
            AppStorageKeys.Notify.loginProblems, .bool, group: "alerts",
            summary: "Alert once when a provider login breaks, until it recovers.",
            fallback: .bool(true)),
    ]

    private static let budget: [UsageSettingDefinition] = [
        UsageSettingDefinition(
            AppStorageKeys.Budget.enabled, .bool, group: "budget", summary: "Track a spend budget.",
            fallback: .bool(false)),
        UsageSettingDefinition(
            AppStorageKeys.Budget.mode, .string, group: "budget",
            summary: "Budget comparison mode.",
            allowed: BudgetMode.allCases.map(\.rawValue), fallback: .string("cap")),
        UsageSettingDefinition(
            AppStorageKeys.Budget.kind, .string, group: "budget",
            summary: "Window the budget applies to.",
            allowed: ["session", "weekly"], fallback: .string("session")),
        UsageSettingDefinition(
            AppStorageKeys.Budget.capPercent, .number, group: "budget",
            summary: "Budget cap as a percentage of the limit.", fallback: .double(50)),
        UsageSettingDefinition(
            AppStorageKeys.Budget.deadline, .number, group: "budget",
            summary: "Unix timestamp the budget is paced towards.", fallback: .double(0)),
    ]

    private static let dashboard: [UsageSettingDefinition] = [
        UsageSettingDefinition(
            "dashPaths", .string, group: "dashboard",
            summary: "Folder scope for the dashboard charts."),
        UsageSettingDefinition(
            "dashRange", .string, group: "dashboard",
            summary: "Dashboard date range.", fallback: .string("all")),
        UsageSettingDefinition(
            "dashSources", .csv, group: "dashboard",
            summary: "Comma separated usage sources included in the dashboard."),
        UsageSettingDefinition(
            "dashKnownSources", .csv, group: "dashboard",
            summary: "Sources seen so far, used to auto-select newly discovered ones."),
        UsageSettingDefinition(
            "dashSourceSelectionVersion", .int, group: "dashboard",
            summary: "Schema version of the stored source selection."),
        UsageSettingDefinition(
            "dashModels", .string, group: "dashboard",
            summary: "Model filter for the dashboard charts."),
        UsageSettingDefinition(
            "dashSort", .string, group: "dashboard", summary: "Model table sort column.",
            fallback: .string("cost")),
        UsageSettingDefinition(
            "dashSortAsc", .bool, group: "dashboard",
            summary: "Sort the model table ascending.", fallback: .bool(false)),
        UsageSettingDefinition(
            "dashHeatMetric", .string, group: "dashboard",
            summary: "Metric the activity heatmap colours by.", allowed: ["tokens", "cost"],
            fallback: .string("tokens")),
        UsageSettingDefinition(
            "projSort", .string, group: "dashboard", summary: "Project drilldown sort column.",
            fallback: .string("cost")),
        UsageSettingDefinition(
            "projSortAsc", .bool, group: "dashboard",
            summary: "Sort the project drilldown ascending.", fallback: .bool(false)),
    ]

}
