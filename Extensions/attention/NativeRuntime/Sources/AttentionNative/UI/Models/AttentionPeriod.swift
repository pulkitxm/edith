internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import Foundation

struct AttentionPeriod: Equatable {
    var selection: DateFilterSelection
    var start: Date
    var end: Date

    init(
        _ selection: DateFilterSelection = .preset(.today), now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let today = DateFilterSelection.preset(.today).interval(now: now, calendar: calendar)
        let interval = selection.interval(now: now, calendar: calendar) ?? today
        self.selection = selection
        start = interval?.start ?? now
        end = interval?.end ?? now
    }

    func days(calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
    }

    var isSingleDay: Bool { days() == 1 }
    var showsSpans: Bool { days() <= 8 }
    var isAllTime: Bool { selection == .preset(.allTime) }

    func interval(now: Date = Date()) -> DateInterval {
        DateInterval(start: start, end: max(start, min(end, now)))
    }

    func comparePeriod(now: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
        guard !isAllTime else { return nil }
        let shift = comparisonShift(now: now, calendar: calendar)
        let previousStart = start.addingTimeInterval(-shift)
        return previousStart >= AttentionRetention.cutoff(now: now) ? shift : nil
    }

    private func comparisonShift(now: Date, calendar: Calendar) -> TimeInterval {
        switch selection {
        case .preset(.thisWeek), .preset(.thisMonth), .preset(.thisYear):
            let prior = selection.stepped(by: -1, now: now, calendar: calendar)
            let priorStart = prior.interval(now: now, calendar: calendar)?.start ?? start
            return start.timeIntervalSince(priorStart)
        default:
            return end.timeIntervalSince(start)
        }
    }

    func isCurrent(now: Date = Date()) -> Bool { end > now }

    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        selection.periodLabel(now: now, calendar: calendar)
    }

    static func earliestDay(now: Date = Date(), calendar: Calendar = .current) -> DateFilterDay {
        DateFilterDay(date: AttentionRetention.cutoff(now: now), calendar: calendar)
    }

    func retentionNote(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let earliest = Self.earliestDay(now: now, calendar: calendar)
        guard DateFilterDay(date: start, calendar: calendar) <= earliest else { return nil }
        return "Attention keeps \(AttentionRetention.days) days, so this starts "
            + earliest.title(calendar: calendar)
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
