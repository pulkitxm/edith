import Foundation
import Testing

import EdithExtensionUI

@Suite struct ActivityCalendarTests {
    @Test func nonfiniteValuesAndExtremeDateRangesRemainBounded() {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: DateComponents(year: 1, month: 1, day: 1))!
        let last = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31))!
        let weeks = ActivityCalendar.weeks(
            days: [
                .init(id: "old", date: first, value: .infinity, level: 99),
                .init(id: "recent", date: last, value: .nan, level: -99),
            ], calendar: calendar)
        #expect(weeks.flatMap(\.cells).count <= 36_531)
        #expect(
            weeks.flatMap(\.cells).allSatisfy { $0.value.isFinite && (-1...4).contains($0.level) })
        #expect(ActivityCalendar.cuts([.infinity, .nan, 1, 2, 3]).allSatisfy { $0.isFinite })
    }

    @Test func sparseDatesKeepTheirWeekdayAndEmptyDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let monday = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        let thursday = try #require(calendar.date(byAdding: .day, value: 3, to: monday))
        let weeks = ActivityCalendar.weeks(
            days: [
                ActivityCalendarDay(id: "monday", date: monday, value: 10),
                ActivityCalendarDay(id: "thursday", date: thursday, value: 40),
            ], calendar: calendar)
        let week = try #require(weeks.first)
        #expect(week.cells.count == 7)
        #expect(week.cells[0].id == "monday")
        #expect(week.cells[3].id == "thursday")
        #expect(week.cells[1].value == 0)
        #expect(week.cells[2].value == 0)
    }

    @Test func emptyAndNonpositiveActivityHaveNoIntensity() {
        #expect(ActivityCalendar.weeks(days: []).isEmpty)
        #expect(ActivityCalendar.cuts([0, -1]).isEmpty)
        #expect(ActivityCalendar.level(0, cuts: [1, 2, 3]) == 0)
        #expect(ActivityCalendar.level(-1, cuts: [1, 2, 3]) == 0)
        #expect(ActivityCalendar.level(1, cuts: [1, 2, 3]) == 1)
        #expect(ActivityCalendar.level(4, cuts: [1, 2, 3]) == 4)
    }
}
