import Foundation

public struct LimitWindow: Sendable {
    public let percent: Double
    public let resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public enum LimitProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }
    public var label: String { self == .codex ? "Codex" : "Claude" }
}

public struct ProviderLimits: Sendable {
    public let provider: LimitProvider
    public let session: LimitWindow?
    public let week: LimitWindow?

    public init(provider: LimitProvider, session: LimitWindow?, week: LimitWindow?) {
        self.provider = provider
        self.session = session
        self.week = week
    }

    public var isAvailable: Bool { session != nil || week != nil }
}

public struct UsageThresholds: Equatable {
    public var warningPercent: Int
    public var criticalPercent: Int
    public static let `default` = UsageThresholds(warningPercent: 60, criticalPercent: 85)

    public init(warningPercent: Int, criticalPercent: Int) {
        self.warningPercent = warningPercent
        self.criticalPercent = criticalPercent
    }

    public static func fromDefaults(_ d: UserDefaults = .standard) -> UsageThresholds {
        UsageThresholds(
            warningPercent: d.object(forKey: AppStorageKeys.Limits.warnPercent) as? Int
                ?? LimitRing.defaultWarnPercent,
            criticalPercent: d.object(forKey: AppStorageKeys.Limits.critPercent) as? Int
                ?? LimitRing.defaultCriticalPercent)
    }
}

public enum UsageLevel: Int, Comparable {
    case green = 0, orange = 1, red = 2
    public static func < (lhs: UsageLevel, rhs: UsageLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func from(pct: Double, thresholds: UsageThresholds) -> UsageLevel {
        if pct >= Double(thresholds.criticalPercent) { return .red }
        if pct >= Double(thresholds.warningPercent) { return .orange }
        return .green
    }
}

public enum PacingZone: String {
    case chill, onTrack, warning, hot
}

public enum LimitWindowKind: String {
    case session, weekly
    public var duration: TimeInterval { self == .session ? 5 * 3600 : 7 * 24 * 3600 }
}

public enum BudgetMode: String, Sendable, CaseIterable {
    case cap, pace
}

public enum BudgetState: String, Sendable {
    case onPace, under, over, exceeded, noData
}

public struct BudgetStatus: Equatable, Sendable {
    public let state: BudgetState
    public let targetPercent: Double
    public let actualPercent: Double
    public let capPercent: Double
    public let dailyBudgetPercent: Double?

    public init(
        state: BudgetState, targetPercent: Double, actualPercent: Double, capPercent: Double,
        dailyBudgetPercent: Double?
    ) {
        self.state = state
        self.targetPercent = targetPercent
        self.actualPercent = actualPercent
        self.capPercent = capPercent
        self.dailyBudgetPercent = dailyBudgetPercent
    }
}

extension LimitMath {
    public static func budgetTarget(
        capPercent: Double, start: Date, deadline: Date, now: Date
    ) -> Double {
        let span = deadline.timeIntervalSince(start)
        guard span > 0 else { return capPercent }
        let t = min(max(now.timeIntervalSince(start) / span, 0), 1)
        return t * capPercent
    }

    public static func dailyBudget(
        actual: Double, capPercent: Double, resetsAt: Date, now: Date
    ) -> Double {
        let remaining = max(0, capPercent - actual)
        let daysLeft = max(1, ceil(max(0, resetsAt.timeIntervalSince(now)) / 86400))
        return remaining / daysLeft
    }

    public static func budgetStatus(
        actual: Double, capPercent: Double, start: Date, deadline: Date, now: Date,
        margin: Double = 5, resetsAt: Date? = nil
    ) -> BudgetStatus {
        let target = budgetTarget(
            capPercent: capPercent, start: start, deadline: deadline, now: now)
        let delta = actual - target
        let state: BudgetState
        if actual >= capPercent {
            state = .exceeded
        } else if delta > margin {
            state = .over
        } else if delta < -margin {
            state = .under
        } else {
            state = .onPace
        }
        let daily = resetsAt.map {
            dailyBudget(actual: actual, capPercent: capPercent, resetsAt: $0, now: now)
        }
        return BudgetStatus(
            state: state, targetPercent: target, actualPercent: actual, capPercent: capPercent,
            dailyBudgetPercent: daily)
    }
}

public enum LimitMath {
    public static let k = 5.0
    public static let projUpper = 1.4
    public static let absoluteLower = 0.50
    public static let absoluteUpper = 1.00
    public static let risingChill = 0.30, risingWarning = 0.55, risingHot = 0.78
    public static let fallingChill = 0.25, fallingWarning = 0.50, fallingHot = 0.73

    public static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard a < b else { return x >= b ? 1 : 0 }
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    public static func confidence(e: Double) -> Double { 1 - exp(-k * max(0, e)) }

    public static func combinedRisk(u: Double, e: Double, m: Double) -> Double {
        if u >= 1.0 { return 1.0 }
        let aRaw = smoothstep(absoluteLower, absoluteUpper, u)
        let projectionHealth = e > 0.0001 ? smoothstep(0.7, 1.0, u / e) : 1.0
        let a = aRaw * projectionHealth
        let b: Double = {
            guard u > 0.0001, e > 0.0001 else { return 0 }
            return smoothstep(1.0, projUpper, u / e) * confidence(e: e)
        }()
        let c = smoothstep(m, m + 0.15, u - e) * confidence(e: e)
        return max(a, max(b, c))
    }

    public static func smartRisk(
        utilization: Double, resetsAt: Date?, windowDuration: TimeInterval,
        pacingMargin: Double, now: Date = Date()
    ) -> Double {
        if utilization >= 100 { return 1.0 }
        let u = max(0, utilization) / 100
        guard let resetsAt, windowDuration > 0 else {
            return smoothstep(absoluteLower, absoluteUpper, u)
        }
        let remaining = max(0, resetsAt.timeIntervalSince(now))
        let e = max(0.0, 1.0 - min(1.0, remaining / windowDuration))
        return combinedRisk(u: u, e: e, m: pacingMargin / 100)
    }

    public static func level(forRisk risk: Double) -> UsageLevel {
        if risk >= 0.78 { return .red }
        if risk >= 0.50 { return .orange }
        return .green
    }

    public static func zone(forRisk risk: Double, previous: PacingZone? = nil) -> PacingZone {
        let r = max(0, min(1, risk))
        func rising() -> PacingZone {
            if r >= risingHot { return .hot }
            if r >= risingWarning { return .warning }
            if r >= risingChill { return .onTrack }
            return .chill
        }
        guard let previous else { return rising() }
        switch previous {
        case .chill: return rising()
        case .onTrack:
            if r >= risingHot { return .hot }
            if r >= risingWarning { return .warning }
            if r < fallingChill { return .chill }
            return .onTrack
        case .warning:
            if r >= risingHot { return .hot }
            if r < fallingChill { return .chill }
            if r < fallingWarning { return .onTrack }
            return .warning
        case .hot:
            if r < fallingChill { return .chill }
            if r < fallingWarning { return .onTrack }
            if r < fallingHot { return .warning }
            return .hot
        }
    }

    public static func pacingDelta(
        utilization: Double, resetsAt: Date, windowDuration: TimeInterval, now: Date = Date()
    ) -> Double {
        let start = resetsAt.addingTimeInterval(-windowDuration)
        let elapsed = min(max(now.timeIntervalSince(start) / windowDuration, 0), 1)
        return utilization - elapsed * 100
    }

    public static func pacingZone(delta: Double, margin: Double) -> PacingZone {
        if delta < -margin { return .chill }
        if delta <= margin { return .onTrack }
        if delta <= margin * 2 { return .warning }
        return .hot
    }
}
