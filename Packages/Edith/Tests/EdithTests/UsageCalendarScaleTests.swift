import EdithKit
import Foundation
import Testing

@Suite struct UsageCalendarScaleTests {
    @Test func tokenOnlyAndCostOnlyActivityShareTheCalendar() throws {
        let start = Date(timeIntervalSince1970: 1_791_158_400)
        let days = [
            DayPoint(id: "small", date: start, cost: 0, tokens: 100),
            DayPoint(id: "medium", date: start.addingTimeInterval(86_400), cost: 0, tokens: 1_000),
            DayPoint(
                id: "large", date: start.addingTimeInterval(172_800), cost: 0, tokens: 775_500_000),
            DayPoint(id: "paid", date: start.addingTimeInterval(259_200), cost: 5, tokens: 0),
            DayPoint(id: "empty", date: start.addingTimeInterval(345_600), cost: 0, tokens: 0),
        ]
        let scale = UsageCalendarScale(days: days)
        #expect(scale.level(for: days[0]) > 0)
        #expect(scale.level(for: days[2]) == 4)
        #expect(scale.level(for: days[3]) > 0)
        #expect(scale.level(for: days[4]) == 0)
        let cells = scale.weeks(days: days).flatMap(\.cells)
        #expect(cells.first { $0.id == "large" }?.level == 4)
        #expect(cells.first { $0.id == "paid" }?.level == 1)
        #expect(cells.first { $0.id == "empty" }?.level == 0)
        #expect(days[2].cost == 0)
        let encoded = try JSONEncoder().encode(scale)
        #expect(try JSONDecoder().decode(UsageCalendarScale.self, from: encoded) == scale)
    }

    @Test func missingDatesAndEmptyHistoryStayUncolored() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let first = Date(timeIntervalSince1970: 1_791_158_400)
        let days = [
            DayPoint(id: "first", date: first, cost: 0, tokens: 10),
            DayPoint(id: "last", date: first.addingTimeInterval(172_800), cost: 0, tokens: 20),
        ]
        let cells = UsageCalendarScale(days: days).weeks(days: days, calendar: calendar)
            .flatMap(\.cells)
        let gap = try #require(cells.first { $0.id.hasPrefix("gap-") })
        #expect(gap.level == 0)
        #expect(cells.filter { $0.date == nil }.allSatisfy { $0.level == -1 })
        #expect(UsageCalendarScale(days: []).weeks(days: []).isEmpty)
    }
}
