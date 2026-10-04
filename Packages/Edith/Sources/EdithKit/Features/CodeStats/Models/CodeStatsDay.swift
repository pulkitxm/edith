import Foundation

public struct CodeStatsDay: Comparable, Hashable, Sendable, Strideable {
    public let ordinal: Int

    public init(ordinal: Int) { self.ordinal = ordinal }

    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public init(year: Int, month: Int, day: Int) {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        ordinal = era * 146_097 + dayOfEra - 719_468
    }

    public var components: (year: Int, month: Int, day: Int) {
        let shifted = ordinal + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    public var string: String {
        let parts = components
        return String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    }

    public var weekdayIndex: Int { ((ordinal % 7) + 11) % 7 }

    public func weekStart(firstWeekday: Int) -> CodeStatsDay {
        advanced(by: -((weekdayIndex - (firstWeekday - 1) + 7) % 7))
    }

    public var monthStart: CodeStatsDay {
        let parts = components
        return CodeStatsDay(year: parts.year, month: parts.month, day: 1)
    }

    public var nextMonthStart: CodeStatsDay {
        let parts = components
        return parts.month == 12
            ? CodeStatsDay(year: parts.year + 1, month: 1, day: 1)
            : CodeStatsDay(year: parts.year, month: parts.month + 1, day: 1)
    }

    public static func < (lhs: CodeStatsDay, rhs: CodeStatsDay) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    public func distance(to other: CodeStatsDay) -> Int { other.ordinal - ordinal }

    public func advanced(by count: Int) -> CodeStatsDay { CodeStatsDay(ordinal: ordinal + count) }
}
