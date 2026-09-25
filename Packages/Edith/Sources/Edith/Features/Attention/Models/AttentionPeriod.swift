import EdithKit
import Foundation

enum AttentionRangePreset: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case last7
    case last14
    case thisMonth
    case lastMonth
    case last30
    case last90
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week"
        case .lastWeek: "Last week"
        case .last7: "Last 7 days"
        case .last14: "Last 14 days"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last30: "Last 30 days"
        case .last90: "Last 90 days"
        case .custom: "Custom range"
        }
    }

    static let groups: [[AttentionRangePreset]] = [
        [.today, .yesterday], [.thisWeek, .lastWeek, .last7, .last14],
        [.thisMonth, .lastMonth, .last30, .last90],
    ]

    var stepsByMonth: Bool { self == .thisMonth || self == .lastMonth }
}

struct AttentionPeriod: Equatable {
    var start: Date
    var end: Date
    var preset: AttentionRangePreset

    init(start: Date, end: Date, preset: AttentionRangePreset) {
        self.start = start
        self.end = max(end, start.addingTimeInterval(3_600))
        self.preset = preset
    }

    init(_ preset: AttentionRangePreset = .today, now: Date = Date(), calendar: Calendar = .current)
    {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: today) ?? today
        }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        switch preset {
        case .today, .custom: self.init(start: today, end: day(1), preset: preset)
        case .yesterday: self.init(start: day(-1), end: today, preset: preset)
        case .thisWeek:
            self.init(start: week?.start ?? day(-6), end: week?.end ?? day(1), preset: preset)
        case .lastWeek:
            let start = (week?.start).flatMap { calendar.date(byAdding: .day, value: -7, to: $0) }
            self.init(start: start ?? day(-13), end: week?.start ?? day(-6), preset: preset)
        case .last7: self.init(start: day(-6), end: day(1), preset: preset)
        case .last14: self.init(start: day(-13), end: day(1), preset: preset)
        case .thisMonth:
            self.init(start: month?.start ?? day(-29), end: month?.end ?? day(1), preset: preset)
        case .lastMonth:
            let start = (month?.start).flatMap {
                calendar.date(byAdding: .month, value: -1, to: $0)
            }
            self.init(start: start ?? day(-59), end: month?.start ?? day(-29), preset: preset)
        case .last30: self.init(start: day(-29), end: day(1), preset: preset)
        case .last90: self.init(start: day(-89), end: day(1), preset: preset)
        }
    }

    static func custom(from: Date, to: Date, calendar: Calendar = .current) -> AttentionPeriod {
        let first = calendar.startOfDay(for: min(from, to))
        let last = calendar.startOfDay(for: max(from, to))
        return AttentionPeriod(
            start: first, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last,
            preset: .custom)
    }

    func days(calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
    }

    var isSingleDay: Bool { days() == 1 }
    var showsSpans: Bool { days() <= 8 }
    var lastDay: Date { end.addingTimeInterval(-1) }

    func interval(now: Date = Date()) -> DateInterval {
        DateInterval(start: start, end: max(start, min(end, now)))
    }

    var comparePeriod: TimeInterval { end.timeIntervalSince(start) }

    func isCurrent(now: Date = Date()) -> Bool { end > now }

    func shifted(by steps: Int, calendar: Calendar = .current) -> AttentionPeriod {
        let from: Date
        let to: Date
        if preset.stepsByMonth {
            from = calendar.date(byAdding: .month, value: steps, to: start) ?? start
            to = calendar.date(byAdding: .month, value: 1, to: from) ?? end
        } else {
            let length = days(calendar: calendar)
            from = calendar.date(byAdding: .day, value: steps * length, to: start) ?? start
            to = calendar.date(byAdding: .day, value: length, to: from) ?? end
        }
        return AttentionPeriod(start: from, end: to, preset: named(from, to, calendar: calendar))
    }

    private func named(_ from: Date, _ to: Date, calendar: Calendar) -> AttentionRangePreset {
        let candidates: [AttentionRangePreset] =
            preset.stepsByMonth ? [.thisMonth, .lastMonth] : AttentionRangePreset.allCases
        return candidates.first {
            $0 != .custom
                && AttentionPeriod($0, calendar: calendar).start == from
                && AttentionPeriod($0, calendar: calendar).end == to
        } ?? (preset.stepsByMonth ? .lastMonth : .custom)
    }

    func title(calendar: Calendar = .current) -> String {
        if preset != .custom, AttentionPeriod(preset, calendar: calendar) == self {
            return preset.title
        }
        if isSingleDay {
            return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        let sameYear = calendar.isDate(start, equalTo: lastDay, toGranularity: .year)
        let from = start.formatted(.dateTime.month(.abbreviated).day())
        let to =
            sameYear
            ? lastDay.formatted(.dateTime.month(.abbreviated).day())
            : lastDay.formatted(.dateTime.year().month(.abbreviated).day())
        return "\(from) to \(to)"
    }
}

enum AttentionDayFilter: String, CaseIterable, Identifiable {
    case all
    case weekdays
    case weekends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All days"
        case .weekdays: "Weekdays"
        case .weekends: "Weekends"
        }
    }

    var weekdays: Set<Int> {
        switch self {
        case .all: []
        case .weekdays: AttentionTimeWindow.weekdays
        case .weekends: AttentionTimeWindow.weekends
        }
    }
}

enum AttentionHourFilter: String, CaseIterable, Identifiable {
    case all
    case work
    case morning
    case afternoon
    case evening
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All day"
        case .work: "Work hours, 9 to 18"
        case .morning: "Mornings, 6 to 12"
        case .afternoon: "Afternoons, 12 to 18"
        case .evening: "Evenings, 18 to 24"
        case .night: "Nights, 0 to 6"
        }
    }

    var hours: (Int, Int) {
        switch self {
        case .all: (0, 24)
        case .work: (9, 18)
        case .morning: (6, 12)
        case .afternoon: (12, 18)
        case .evening: (18, 24)
        case .night: (0, 6)
        }
    }
}

extension AttentionTimeWindow {
    var title: String {
        var parts: [String] = []
        if !allDays {
            if weekdays == AttentionTimeWindow.weekdays {
                parts.append("Weekdays")
            } else if weekdays == AttentionTimeWindow.weekends {
                parts.append("Weekends")
            } else {
                let symbols = Calendar.current.shortWeekdaySymbols
                parts.append(weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: ", "))
            }
        }
        if !allHours { parts.append(String(format: "%02d:00 to %02d:00", startHour, endHour % 24)) }
        return parts.isEmpty ? "All hours" : parts.joined(separator: " · ")
    }
}
