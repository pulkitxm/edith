import Foundation

public struct MachineUsageFreshness: Equatable, Sendable {
    public static let refreshInterval: TimeInterval = 30 * 60
    public static let tolerance: TimeInterval = 10 * 60

    public let collectedAt: Date
    public let age: TimeInterval
    public let isStale: Bool
    public let failure: String?

    public init(
        collectedAt: Date, now: Date = Date(),
        refreshInterval: TimeInterval = Self.refreshInterval,
        tolerance: TimeInterval = Self.tolerance,
        failure: String? = nil
    ) {
        self.collectedAt = collectedAt
        age = max(0, now.timeIntervalSince(collectedAt))
        isStale = age > refreshInterval + tolerance
        self.failure = failure
    }

    public var needsAttention: Bool { isStale || failure != nil }

    public var ageLabel: String {
        let minutes = Int(age) / 60
        if minutes == 0 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0
                ? "\(hours)h ago"
                : "\(hours)h \(remainingMinutes)m ago"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0
            ? "\(days)d ago"
            : "\(days)d \(remainingHours)h ago"
    }

    public var statusLabel: String {
        let collected = isStale ? "usage stale · collected \(ageLabel)" : "collected \(ageLabel)"
        guard let failure else { return collected }
        return collected + " · last refresh failed: " + failure
    }
}
