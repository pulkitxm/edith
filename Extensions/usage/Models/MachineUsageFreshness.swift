import Foundation

public struct MachineUsageFreshness: Equatable, Sendable {
    public static let tolerance: TimeInterval = 5 * 60

    public let collectedAt: Date
    public let age: TimeInterval
    public let isStale: Bool

    public init(
        collectedAt: Date, now: Date = Date(),
        refreshInterval: TimeInterval = 1800,
        tolerance: TimeInterval = Self.tolerance
    ) {
        self.collectedAt = collectedAt
        age = max(0, now.timeIntervalSince(collectedAt))
        isStale = age > refreshInterval + tolerance
    }

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
        isStale ? "usage stale · collected \(ageLabel)" : "collected \(ageLabel)"
    }
}
