import EdithCore
import Foundation

public struct WindowSwitcherWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let appName: String
    public let bundleIdentifier: String
    public let title: String
    public let isMinimized: Bool
    public let pid: Int32

    public init(
        id: String, appName: String, bundleIdentifier: String, title: String,
        isMinimized: Bool, pid: Int32
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.isMinimized = isMinimized
        self.pid = pid
    }

    public var displayTitle: String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? appName : cleaned
    }
}

public struct WindowSwitcherGroup: Equatable, Identifiable, Sendable {
    public let appName: String
    public let windows: [WindowSwitcherWindow]

    public var id: String { windows.first?.bundleIdentifier ?? appName }
}

public struct WindowSwitcherRuleSet: Equatable, Sendable {
    public let included: Set<String>
    public let hidden: Set<String>

    public init(included: Set<String> = [], hidden: Set<String> = []) {
        self.included = included
        self.hidden = hidden
    }

    public init(includedCSV: String, hiddenCSV: String) {
        included = Self.identifiers(includedCSV)
        hidden = Self.identifiers(hiddenCSV)
    }

    public func permits(bundleIdentifier: String, regular: Bool) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        if hidden.contains(identifier) { return false }
        return regular || included.contains(identifier)
    }

    private static func identifiers(_ csv: String) -> Set<String> {
        Set(
            csv.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })
    }
}

public enum WindowSwitcherCollection {
    public static func filtered(
        _ windows: [WindowSwitcherWindow], query: String
    ) -> [WindowSwitcherWindow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return windows }
        return windows.filter {
            $0.appName.localizedCaseInsensitiveContains(needle)
                || $0.title.localizedCaseInsensitiveContains(needle)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(needle)
        }
    }

    public static func grouped(
        _ windows: [WindowSwitcherWindow]
    ) -> [WindowSwitcherGroup] {
        var order: [String] = []
        var buckets: [String: [WindowSwitcherWindow]] = [:]
        for window in windows {
            if buckets[window.bundleIdentifier] == nil { order.append(window.bundleIdentifier) }
            buckets[window.bundleIdentifier, default: []].append(window)
        }
        return order.compactMap { identifier in
            guard let windows = buckets[identifier], let first = windows.first else { return nil }
            return WindowSwitcherGroup(appName: first.appName, windows: windows)
        }
    }
}

public enum WindowSwitcherOperation: String, CaseIterable, Sendable {
    case list
    case show
    case activate
    case cycle

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "windowSwitcher.list"),
                summary: "List windows visible to Edith.", cli: ["windows", "ls"], effect: .read)
        case .show:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "windowSwitcher.show"),
                summary: "Open the searchable window switcher.", cli: ["windows", "show"],
                effect: .interactive)
        case .activate:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "windowSwitcher.activate"),
                summary: "Activate one window.", cli: ["windows", "activate"],
                effect: .interactive)
        case .cycle:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "windowSwitcher.cycle"),
                summary: "Cycle windows of the front application.",
                cli: ["windows", "cycle"], effect: .interactive)
        }
    }
}

public enum WindowSwitcherIPC {
    public static let requestIDKey = "requestID"
    public static let operationKey = "operation"
    public static let windowIDKey = "windowID"
    public static let statusKey = "status"
    public static let payloadKey = "payload"

    public static func encode(_ windows: [WindowSwitcherWindow]) -> String {
        guard let data = try? JSONEncoder().encode(windows) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ value: String) -> [WindowSwitcherWindow] {
        (try? JSONDecoder().decode([WindowSwitcherWindow].self, from: Data(value.utf8))) ?? []
    }
}
