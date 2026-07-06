import Foundation

public enum StandupSchedule {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func isDue(
        now: Date, scheduledMinutesFromMidnight: Int, lastRunDay: String?,
        calendar: Calendar = .current
    ) -> Bool {
        let today = dayKey(now, calendar: calendar)
        guard lastRunDay != today else { return false }
        guard let lastRunDay, let lastDate = date(fromDayKey: lastRunDay, calendar: calendar)
        else {
            return hasReachedScheduledTime(
                now: now, minutes: scheduledMinutesFromMidnight, calendar: calendar)
        }
        let daysSince =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: lastDate), to: calendar.startOfDay(for: now)
            ).day ?? 0
        if daysSince >= 2 { return true }
        return hasReachedScheduledTime(
            now: now, minutes: scheduledMinutesFromMidnight, calendar: calendar)
    }

    private static func hasReachedScheduledTime(now: Date, minutes: Int, calendar: Calendar)
        -> Bool
    {
        let start = calendar.startOfDay(for: now)
        let scheduled = calendar.date(byAdding: .minute, value: minutes, to: start)!
        return now >= scheduled
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return calendar.date(from: comps)
    }
}
