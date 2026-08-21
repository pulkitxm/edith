import Foundation

public enum AttentionPaths {
    nonisolated(unsafe) public static var root: URL = AppData.supportDir

    public static var directory: URL { root.appendingPathComponent("attention") }
    public static var eventsDirectory: URL { directory.appendingPathComponent("events") }
    public static var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    public static var activeFocusFile: URL { directory.appendingPathComponent("active-focus.json") }
    public static var focusHistoryFile: URL { directory.appendingPathComponent("focus.jsonl") }
    public static var lockFile: URL { directory.appendingPathComponent(".lock") }

    public static func eventFile(for date: Date, calendar: Calendar = utcCalendar) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(
            format: "%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return eventsDirectory.appendingPathComponent(name)
    }

    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
