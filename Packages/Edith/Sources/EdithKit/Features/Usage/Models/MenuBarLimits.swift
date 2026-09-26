import Foundation

public enum LimitWindowSlot: String, CaseIterable, Codable, Sendable {
    case session, week, fable

    public var kind: LimitWindowKind { self == .session ? .session : .weekly }

    public var menuBarLabel: String { menuBarLabel(for: .claude) }

    public func menuBarLabel(for provider: LimitProvider) -> String {
        switch (provider, self) {
        case (.cursor, .week): return "plan"
        case (.cursor, .session): return "od"
        case (.cursor, .fable): return "plan"
        case (_, .session): return "5h"
        case (_, .week): return "7d"
        case (_, .fable): return "F"
        }
    }

    public var settingsLabel: String { settingsLabel(for: .claude) }

    public func settingsLabel(for provider: LimitProvider) -> String {
        switch (provider, self) {
        case (.cursor, .week): return "Plan"
        case (.cursor, .session): return "On-demand"
        case (.cursor, .fable): return "Plan"
        case (_, .session): return "5h"
        case (_, .week): return "7d"
        case (_, .fable): return "Fable"
        }
    }

    public func pacingDuration(for provider: LimitProvider) -> TimeInterval {
        provider == .cursor ? LimitProvider.cursorBillingCycle : kind.duration
    }
}

public enum MenuBarLimitsStyle: String, CaseIterable, Sendable {
    case stacked, tagged, slash
}

public struct MenuBarLimitSegment: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case percent(Int)
        case missing
        case masked
    }

    public let slot: LimitWindowSlot
    public let value: Value
    public let window: LimitWindow?

    public init(slot: LimitWindowSlot, value: Value, window: LimitWindow?) {
        self.slot = slot
        self.value = value
        self.window = window
    }
}

public struct MenuBarProviderGroup: Equatable, Sendable {
    public let provider: LimitProvider
    public let segments: [MenuBarLimitSegment]

    public init(provider: LimitProvider, segments: [MenuBarLimitSegment]) {
        self.provider = provider
        self.segments = segments
    }
}

public enum MenuBarLimits {
    public static func slots(for provider: LimitProvider) -> [LimitWindowSlot] {
        switch provider {
        case .claude: [.session, .week, .fable]
        case .codex: [.session, .week]
        case .cursor: [.week]
        }
    }

    public static func selectionKey(for provider: LimitProvider) -> String {
        switch provider {
        case .claude: AppStorageKeys.MenuBar.claudeWindows
        case .codex: AppStorageKeys.MenuBar.codexWindows
        case .cursor: AppStorageKeys.MenuBar.cursorWindows
        }
    }

    public static func parseSelection(
        _ raw: String?, provider: LimitProvider
    ) -> [LimitWindowSlot] {
        let all = slots(for: provider)
        guard let raw else { return all }
        let chosen = Set(
            raw.split(separator: ",").compactMap {
                LimitWindowSlot(rawValue: $0.trimmingCharacters(in: .whitespaces))
            })
        return all.filter(chosen.contains)
    }

    public static func encodeSelection(_ slots: [LimitWindowSlot]) -> String {
        slots.map(\.rawValue).joined(separator: ",")
    }

    public static func selection(
        for provider: LimitProvider, defaults: UserDefaults
    ) -> [LimitWindowSlot] {
        parseSelection(defaults.string(forKey: selectionKey(for: provider)), provider: provider)
    }

    public static func style(_ defaults: UserDefaults) -> MenuBarLimitsStyle {
        MenuBarLimitsStyle(
            rawValue: defaults.string(forKey: AppStorageKeys.MenuBar.limitsStyle) ?? "")
            ?? .stacked
    }

    public static func groups(
        providers: [ProviderLimits], selection: (LimitProvider) -> [LimitWindowSlot],
        masked: Bool
    ) -> [MenuBarProviderGroup] {
        providers.compactMap { limits in
            let slots = selection(limits.provider)
            guard !slots.isEmpty else { return nil }
            let segments = slots.map { slot -> MenuBarLimitSegment in
                let window = limits.window(for: slot)
                let value: MenuBarLimitSegment.Value
                if masked {
                    value = .masked
                } else if let window {
                    value = .percent(Int(window.percent.rounded()))
                } else {
                    value = .missing
                }
                return MenuBarLimitSegment(slot: slot, value: value, window: window)
            }
            return MenuBarProviderGroup(provider: limits.provider, segments: segments)
        }
    }
}
