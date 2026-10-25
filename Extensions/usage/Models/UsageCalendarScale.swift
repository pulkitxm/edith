import Foundation

public struct UsageCalendarScale: Codable, Equatable, Sendable {
    private let tokenCuts: [Double]
    private let costCuts: [Double]

    public init(days: [DayPoint]) {
        tokenCuts = ActivityCalendar.cuts(days.map(\.tokens))
        costCuts = ActivityCalendar.cuts(days.map(\.cost))
    }

    public func level(for day: DayPoint) -> Int {
        max(
            ActivityCalendar.level(day.tokens, cuts: tokenCuts),
            ActivityCalendar.level(day.cost, cuts: costCuts))
    }

    public func weeks(
        days: [DayPoint], calendar: Calendar = .current
    ) -> [ActivityCalendarWeek] {
        ActivityCalendar.weeks(
            days: days.map {
                ActivityCalendarDay(id: $0.id, date: $0.date, value: Double(level(for: $0)))
            }, calendar: calendar, cuts: [1, 2, 3])
    }
}
