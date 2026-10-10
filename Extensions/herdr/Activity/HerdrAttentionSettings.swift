import Foundation

public struct HerdrAttentionSettings: Codable, Equatable, Sendable {
    public static let stuckMinutesRange = 2...120
    public static let defaultStuckMinutes = 10

    public var blocked: Bool
    public var finished: Bool
    public var errors: Bool
    public var stuck: Bool
    public var openDiff: Bool
    public var monitoring: Bool
    public var stuckMonitoring: Bool { stuck || monitoring }
    public var stuckMinutes: Int

    public init(
        blocked: Bool = true, finished: Bool = true, errors: Bool = true, stuck: Bool = false,
        openDiff: Bool = false, stuckMinutes: Int = defaultStuckMinutes, monitoring: Bool = false
    ) {
        self.blocked = blocked
        self.finished = finished
        self.errors = errors
        self.stuck = stuck
        self.openDiff = openDiff
        self.stuckMinutes = stuckMinutes
        self.monitoring = monitoring
    }

    public init(defaults: UserDefaults) {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        let minutes = defaults.object(forKey: HerdrAttentionSettings.Keys.stuckMinutes) as? Int
        self.init(
            blocked: flag(HerdrAttentionSettings.Keys.notifyWhenBlocked, true),
            finished: flag(HerdrAttentionSettings.Keys.notifyWhenFinished, true),
            errors: flag(HerdrAttentionSettings.Keys.notifyOnErrors, true),
            stuck: flag(HerdrAttentionSettings.Keys.notifyWhenStuck, false),
            openDiff: flag(HerdrAttentionSettings.Keys.openDiffWhenFinished, false),
            stuckMinutes: min(
                Self.stuckMinutesRange.upperBound,
                max(Self.stuckMinutesRange.lowerBound, minutes ?? Self.defaultStuckMinutes)),
            monitoring: AgentActivitySettings.load(in: defaults).monitorTerminalAttention)
    }

    public enum Keys {
        public static let notifyWhenBlocked = "agentNotifyWhenBlocked"
        public static let notifyWhenFinished = "agentNotifyWhenFinished"
        public static let notifyOnErrors = "agentNotifyOnErrors"
        public static let notifyWhenStuck = "agentNotifyWhenStuck"
        public static let stuckMinutes = "agentStuckMinutes"
        public static let openDiffWhenFinished = "agentOpenDiffWhenFinished"
    }

    public func save(in defaults: UserDefaults) {
        defaults.set(blocked, forKey: Keys.notifyWhenBlocked)
        defaults.set(finished, forKey: Keys.notifyWhenFinished)
        defaults.set(errors, forKey: Keys.notifyOnErrors)
        defaults.set(stuck, forKey: Keys.notifyWhenStuck)
        defaults.set(openDiff, forKey: Keys.openDiffWhenFinished)
        defaults.set(min(120, max(2, stuckMinutes)), forKey: Keys.stuckMinutes)
    }

    public var anyEnabled: Bool { blocked || finished || errors || stuck || openDiff || monitoring }
}
