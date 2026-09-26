import Foundation

public struct LimitWindow: Equatable, Codable, Sendable {
    public let percent: Double
    public let resetsAt: Date?
    public let period: String?

    public init(percent: Double, resetsAt: Date?, period: String? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.period = period
    }
}

public struct GrokProductShare: Codable, Equatable, Sendable {
    public var name: String
    public var percent: Double

    public init(name: String, percent: Double) {
        self.name = name
        self.percent = percent
    }
}

public struct GrokAllowance: Codable, Equatable, Sendable {
    public var period: String
    public var tier: String?
    public var products: [GrokProductShare]
    public var onDemandUsed: Double
    public var onDemandCap: Double
    public var prepaidBalance: Double

    public init(
        period: String, tier: String?, products: [GrokProductShare], onDemandUsed: Double,
        onDemandCap: Double, prepaidBalance: Double
    ) {
        self.period = period
        self.tier = tier
        self.products = products
        self.onDemandUsed = onDemandUsed
        self.onDemandCap = onDemandCap
        self.prepaidBalance = prepaidBalance
    }

    public var summary: String {
        var parts: [String] = []
        if let tier, !tier.isEmpty { parts.append(tier) }
        if !products.isEmpty {
            parts.append(
                products.map { "\($0.name) \(Int($0.percent.rounded()))%" }.joined(
                    separator: " · "))
        }
        return parts.joined(separator: " · ")
    }

    public var extraLine: String? {
        var parts: [String] = []
        if prepaidBalance > 0 { parts.append("Extra credits \(Self.money(prepaidBalance))") }
        if onDemandCap > 0 || onDemandUsed > 0 {
            parts.append(
                "Pay as you go \(Self.money(onDemandUsed)) of \(Self.money(onDemandCap))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

public enum GrokPeriod {
    public static func canonical(_ raw: String?) -> String {
        let stripped = (raw ?? "")
            .replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if stripped.isEmpty { return "weekly" }
        return stripped
    }

    public static func mark(_ period: String?) -> String {
        switch canonical(period) {
        case "monthly": "Mo"
        case "daily": "Day"
        case "weekly": "Wk"
        default: "Use"
        }
    }

    public static func title(_ period: String?) -> String {
        switch canonical(period) {
        case "monthly": "Monthly allowance"
        case "daily": "Daily allowance"
        case "weekly": "Weekly allowance"
        default: "Allowance"
        }
    }

    public static func duration(_ period: String?) -> TimeInterval {
        switch canonical(period) {
        case "monthly": 30 * 24 * 3600
        case "daily": 24 * 3600
        default: 7 * 24 * 3600
        }
    }
}

public enum LimitProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case grok

    public static let cursorBillingCycle: TimeInterval = 30 * 24 * 3600

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .grok: "Grok"
        }
    }
}

public struct ProviderLimits: Sendable {
    public let provider: LimitProvider
    public let session: LimitWindow?
    public let week: LimitWindow?
    public let fable: LimitWindow?
    public let grok: GrokAllowance?

    public init(
        provider: LimitProvider, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil, grok: GrokAllowance? = nil
    ) {
        self.provider = provider
        self.session = session
        self.week = week
        self.fable = fable
        self.grok = grok
    }

    public var isAvailable: Bool { session != nil || week != nil || fable != nil }

    public func window(for slot: LimitWindowSlot) -> LimitWindow? {
        switch slot {
        case .session: return session
        case .week: return week
        case .fable: return fable
        }
    }
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
}
