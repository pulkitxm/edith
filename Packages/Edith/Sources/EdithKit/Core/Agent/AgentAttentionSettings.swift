import Foundation

public struct AgentAttentionSettings: Equatable, Sendable {
    public static let stuckMinutesRange = 2...120
    public static let defaultStuckMinutes = 10

    public var blocked: Bool
    public var finished: Bool
    public var errors: Bool
    public var stuck: Bool
    public var openDiff: Bool
    public var stuckMinutes: Int

    public init(
        blocked: Bool = true, finished: Bool = true, errors: Bool = true, stuck: Bool = false,
        openDiff: Bool = false, stuckMinutes: Int = defaultStuckMinutes
    ) {
        self.blocked = blocked
        self.finished = finished
        self.errors = errors
        self.stuck = stuck
        self.openDiff = openDiff
        self.stuckMinutes = stuckMinutes
    }

    public init(defaults: UserDefaults) {
        let herdr = defaults.bool(forKey: AppStorageKeys.Tabs.herdrEnabled)
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            herdr && (defaults.object(forKey: key) as? Bool ?? fallback)
        }
        let minutes = defaults.object(forKey: AgentSettingsKeys.stuckMinutes) as? Int
        self.init(
            blocked: flag(AgentSettingsKeys.notifyWhenBlocked, true),
            finished: flag(AgentSettingsKeys.notifyWhenFinished, true),
            errors: flag(AgentSettingsKeys.notifyOnErrors, true),
            stuck: flag(AgentSettingsKeys.notifyWhenStuck, false),
            openDiff: flag(AgentSettingsKeys.openDiffWhenFinished, false),
            stuckMinutes: min(
                Self.stuckMinutesRange.upperBound,
                max(Self.stuckMinutesRange.lowerBound, minutes ?? Self.defaultStuckMinutes)))
    }

    public var anyEnabled: Bool { blocked || finished || errors || stuck || openDiff }
}
