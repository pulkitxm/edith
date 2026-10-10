import Foundation

public struct HostCronSchedule: Equatable, Sendable {
    public struct ParseError: LocalizedError, Equatable, Sendable {
        public let errorDescription: String?
    }

    public let expression: String
    private let minutes: Set<Int>
    private let hours: Set<Int>
    private let daysOfMonth: Set<Int>
    private let months: Set<Int>
    private let weekdays: Set<Int>
    private let restrictsDayOfMonth: Bool
    private let restrictsWeekday: Bool

    public init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else {
            throw ParseError(
                errorDescription:
                    "A cron expression has five fields: minute hour day month weekday."
            )
        }
        self.expression = fields.joined(separator: " ")
        minutes = try Self.values(fields[0], name: "minute", range: 0...59)
        hours = try Self.values(fields[1], name: "hour", range: 0...23)
        daysOfMonth = try Self.values(fields[2], name: "day", range: 1...31)
        months = try Self.values(fields[3], name: "month", range: 1...12)
        weekdays = Set(try Self.values(fields[4], name: "weekday", range: 0...7).map { $0 % 7 })
        restrictsDayOfMonth = !fields[2].hasPrefix("*")
        restrictsWeekday = !fields[4].hasPrefix("*")
    }

    public func next(
        after date: Date, calendar: Calendar = .current, horizon: TimeInterval = 5 * 366 * 86_400
    ) -> Date? {
        guard
            var candidate = calendar.nextDate(
                after: date, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
        else { return nil }
        let limit = date.addingTimeInterval(horizon)
        while candidate <= limit {
            let parts = calendar.dateComponents(
                [.month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month = parts.month, let day = parts.day, let hour = parts.hour,
                let minute = parts.minute, let weekday = parts.weekday
            else { return nil }
            if !months.contains(month) {
                guard let advanced = start(of: .month, after: candidate, calendar: calendar)
                else { return nil }
                candidate = advanced
            } else if !matchesDay(day: day, weekday: weekday - 1) {
                guard let advanced = start(of: .day, after: candidate, calendar: calendar)
                else { return nil }
                candidate = advanced
            } else if !hours.contains(hour) {
                guard let advanced = start(of: .hour, after: candidate, calendar: calendar)
                else { return nil }
                candidate = advanced
            } else if !minutes.contains(minute) {
                guard let advanced = calendar.date(byAdding: .minute, value: 1, to: candidate)
                else { return nil }
                candidate = advanced
            } else {
                return candidate
            }
        }
        return nil
    }

    private func matchesDay(day: Int, weekday: Int) -> Bool {
        let dayMatches = daysOfMonth.contains(day)
        let weekdayMatches = weekdays.contains(weekday)
        if restrictsDayOfMonth && restrictsWeekday { return dayMatches || weekdayMatches }
        if restrictsWeekday { return weekdayMatches }
        return dayMatches
    }

    private func start(
        of component: Calendar.Component, after date: Date, calendar: Calendar
    ) -> Date? {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return nil }
        return interval.end
    }

    private static func values(
        _ field: String, name: String, range: ClosedRange<Int>
    ) throws -> Set<Int> {
        var result = Set<Int>()
        for term in field.split(separator: ",", omittingEmptySubsequences: false) {
            result.formUnion(try termValues(String(term), name: name, range: range))
        }
        return result
    }

    private static func termValues(
        _ term: String, name: String, range: ClosedRange<Int>
    ) throws -> Set<Int> {
        let stepParts = term.split(separator: "/", omittingEmptySubsequences: false)
        guard stepParts.count <= 2 else { throw invalid(name, term) }
        var step = 1
        if stepParts.count == 2 {
            guard let parsed = Int(stepParts[1]), parsed > 0 else { throw invalid(name, term) }
            step = parsed
        }
        let base = String(stepParts[0])
        let bounds: ClosedRange<Int>
        if base == "*" {
            bounds = range
        } else {
            let ends = base.split(separator: "-", omittingEmptySubsequences: false)
            guard ends.count <= 2, let low = Int(ends[0]), range.contains(low) else {
                throw invalid(name, term)
            }
            if ends.count == 2 {
                guard let high = Int(ends[1]), range.contains(high), high >= low else {
                    throw invalid(name, term)
                }
                bounds = low...high
            } else if stepParts.count == 2 {
                bounds = low...range.upperBound
            } else {
                bounds = low...low
            }
        }
        return Set(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
    }

    private static func invalid(_ name: String, _ term: String) -> ParseError {
        ParseError(errorDescription: "The \(name) field has an invalid value: \(term).")
    }
}
