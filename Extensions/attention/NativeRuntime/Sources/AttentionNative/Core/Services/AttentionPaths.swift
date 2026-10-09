@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import Foundation

enum AttentionPaths {
    nonisolated(unsafe) static var root: URL = ExtensionData.root

    static var directory: URL { root.appendingPathComponent("attention") }
    static var eventsDirectory: URL { directory.appendingPathComponent("events") }
    static var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    static var activeFocusFile: URL { directory.appendingPathComponent("active-focus.json") }
    static var focusHistoryFile: URL { directory.appendingPathComponent("focus.jsonl") }
    static var lockFile: URL { directory.appendingPathComponent(".lock") }

    static func eventFile(for date: Date, calendar: Calendar = utcCalendar) -> URL {
        let name = CalendarDay.stamp(date, calendar: calendar) + ".jsonl"
        return eventsDirectory.appendingPathComponent(name)
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
