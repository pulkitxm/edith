import Foundation
import Testing

@testable import EdithKit

@Suite struct StandupDateRangeTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func mondayReachesBackToFriday() {
        let monday = date(2024, 1, 8)
        #expect(utc.component(.weekday, from: monday) == 2)
        let range = StandupDateRange.range(today: monday, calendar: utc)
        #expect(StandupSchedule.dayKey(range.since, calendar: utc) == "2024-01-05")
        #expect(StandupSchedule.dayKey(range.until, calendar: utc) == "2024-01-08")
    }

    @Test func weekdayCoversOnlyYesterday() {
        let wednesday = date(2024, 1, 10)
        let range = StandupDateRange.range(today: wednesday, calendar: utc)
        #expect(StandupSchedule.dayKey(range.since, calendar: utc) == "2024-01-09")
        #expect(StandupSchedule.dayKey(range.until, calendar: utc) == "2024-01-10")
    }

    @Test func dayQueryIsSingleDayOnWeekdays() {
        let wednesday = date(2024, 1, 10)
        let range = StandupDateRange.range(today: wednesday, calendar: utc)
        #expect(StandupDateRange.dayQuery(range, calendar: utc) == "2024-01-09")
    }

    @Test func dayQuerySpansFridayThroughSundayOnMonday() {
        let monday = date(2024, 1, 8)
        let range = StandupDateRange.range(today: monday, calendar: utc)
        #expect(StandupDateRange.dayQuery(range, calendar: utc) == "2024-01-05..2024-01-07")
    }
}
