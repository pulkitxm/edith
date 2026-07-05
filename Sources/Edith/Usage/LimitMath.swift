import Foundation

struct UsageThresholds: Equatable {
    var warningPercent: Int
    var criticalPercent: Int
    static let `default` = UsageThresholds(warningPercent: 60, criticalPercent: 85)

    static func fromDefaults(_ d: UserDefaults = .standard) -> UsageThresholds {
        UsageThresholds(
            warningPercent: d.object(forKey: "warnPercent") as? Int ?? 60,
            criticalPercent: d.object(forKey: "critPercent") as? Int ?? 85)
    }
}

enum UsageLevel: Int, Comparable {
    case green = 0, orange = 1, red = 2
    static func < (lhs: UsageLevel, rhs: UsageLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    static func from(pct: Double, thresholds: UsageThresholds) -> UsageLevel {
        if pct >= Double(thresholds.criticalPercent) { return .red }
        if pct >= Double(thresholds.warningPercent) { return .orange }
        return .green
    }
}

enum PacingZone: String {
    case chill, onTrack, warning, hot
}

enum LimitWindowKind: String {
    case session, weekly
    var duration: TimeInterval { self == .session ? 5 * 3600 : 7 * 24 * 3600 }
}

enum LimitMath {
    static let k = 5.0
    static let projUpper = 1.4
    static let absoluteLower = 0.50
    static let absoluteUpper = 1.00
    static let risingChill = 0.30, risingWarning = 0.55, risingHot = 0.78
    static let fallingChill = 0.25, fallingWarning = 0.50, fallingHot = 0.73

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard a < b else { return x >= b ? 1 : 0 }
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func confidence(e: Double) -> Double { 1 - exp(-k * max(0, e)) }

    static func combinedRisk(u: Double, e: Double, m: Double) -> Double {
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

    static func smartRisk(
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

    static func level(forRisk risk: Double) -> UsageLevel {
        if risk >= 0.78 { return .red }
        if risk >= 0.50 { return .orange }
        return .green
    }

    static func zone(forRisk risk: Double, previous: PacingZone? = nil) -> PacingZone {
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

    static func pacingDelta(
        utilization: Double, resetsAt: Date, windowDuration: TimeInterval, now: Date = Date()
    ) -> Double {
        let start = resetsAt.addingTimeInterval(-windowDuration)
        let elapsed = min(max(now.timeIntervalSince(start) / windowDuration, 0), 1)
        return utilization - elapsed * 100
    }

    static func pacingZone(delta: Double, margin: Double) -> PacingZone {
        if delta < -margin { return .chill }
        if delta <= margin { return .onTrack }
        if delta <= margin * 2 { return .warning }
        return .hot
    }
}
