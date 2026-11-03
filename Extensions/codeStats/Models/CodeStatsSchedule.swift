import EdithExtensionSupport
import Foundation

public enum CodeStatsSchedule: Codable, Equatable, Hashable, Sendable {
    case manual
    case hourly(every: Int)
    case daily(hour: Int)
    case weekly(weekday: Int, hour: Int)

    private var slot: DateComponents? {
        switch self {
        case .manual, .hourly:
            return nil
        case .daily(let hour):
            return DateComponents(hour: min(max(hour, 0), 23), minute: 0, second: 0)
        case .weekly(let weekday, let hour):
            return DateComponents(
                hour: min(max(hour, 0), 23), minute: 0, second: 0,
                weekday: min(max(weekday, 1), 7))
        }
    }

    public func nextRun(after lastRun: Date?, calendar: Calendar) -> Date? {
        guard let lastRun else { return nil }
        if case .hourly(let every) = self {
            return lastRun.addingTimeInterval(TimeInterval(max(every, 1)) * 3600)
        }
        guard let slot else { return nil }
        return calendar.nextDate(
            after: lastRun, matching: slot, matchingPolicy: .nextTime,
            repeatedTimePolicy: .first, direction: .forward)
    }

    public func isDue(lastRun: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let next = nextRun(after: lastRun, calendar: calendar) else {
            return false
        }
        return next <= now
    }
}
