import Foundation

public enum StandupDateRange {
    public struct Range: Equatable {
        public let since: Date
        public let until: Date
        public init(since: Date, until: Date) {
            self.since = since
            self.until = until
        }
    }

    public static func range(today: Date, calendar: Calendar = .current) -> Range {
        let start = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: start)
        let daysBack = weekday == 2 ? 3 : 1
        let since = calendar.date(byAdding: .day, value: -daysBack, to: start)!
        return Range(since: since, until: start)
    }

    public static func dayQuery(_ range: Range, calendar: Calendar = .current) -> String {
        let sinceDay = ymdFormatter.string(from: range.since)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: range.until)!
        let untilDay = ymdFormatter.string(from: lastDay)
        return sinceDay == untilDay ? sinceDay : "\(sinceDay)..\(untilDay)"
    }

    public static func gitDateString(_ date: Date) -> String {
        ymdFormatter.string(from: date)
    }

    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
