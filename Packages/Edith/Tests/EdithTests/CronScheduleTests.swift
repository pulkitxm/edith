import Foundation
import Testing

@testable import EdithKit

@Suite struct CronScheduleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func next(_ expression: String, after start: Date) throws -> Date? {
        try CronSchedule(expression).next(after: start, calendar: calendar)
    }

    @Test func stepsFireOnTheNextBoundary() throws {
        #expect(
            try next("*/15 * * * *", after: date(2026, 3, 1, 10, 2)) == date(2026, 3, 1, 10, 15))
        #expect(
            try next("*/15 * * * *", after: date(2026, 3, 1, 10, 45)) == date(2026, 3, 1, 11, 0))
    }

    @Test func aRunNeverFiresAtTheInstantItWasAskedAfter() throws {
        let start = date(2026, 3, 1, 10, 15)
        #expect(try next("15 10 * * *", after: start) == date(2026, 3, 2, 10, 15))
    }

    @Test func dailyTimesRollOverMonthsAndYears() throws {
        #expect(try next("30 2 * * *", after: date(2026, 12, 31, 3, 0)) == date(2027, 1, 1, 2, 30))
        #expect(try next("0 0 1 * *", after: date(2026, 1, 31, 12, 0)) == date(2026, 2, 1, 0, 0))
    }

    @Test func weekdaysAcceptSevenAsSunday() throws {
        let saturday = date(2026, 3, 7, 12, 0)
        #expect(try next("0 9 * * 7", after: saturday) == date(2026, 3, 8, 9, 0))
        #expect(try next("0 9 * * 0", after: saturday) == date(2026, 3, 8, 9, 0))
        #expect(try next("0 9 * * 1-5", after: saturday) == date(2026, 3, 9, 9, 0))
    }

    @Test func dayAndWeekdayBothRestrictedMatchEither() throws {
        let start = date(2026, 3, 1, 0, 0)
        #expect(try next("0 0 15 * 1", after: start) == date(2026, 3, 2, 0, 0))
    }

    @Test func listsRangesAndSteppedRangesCombine() throws {
        #expect(
            try next("5,10-12/2 * * * *", after: date(2026, 3, 1, 10, 6))
                == date(2026, 3, 1, 10, 10))
        #expect(
            try next("5,10-12/2 * * * *", after: date(2026, 3, 1, 10, 10))
                == date(2026, 3, 1, 10, 12))
    }

    @Test func impossibleDatesNeverFire() throws {
        #expect(try next("0 0 31 2 *", after: date(2026, 3, 1, 0, 0)) == nil)
    }

    @Test func malformedExpressionsAreRefusedWithAReason() {
        for expression in [
            "", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *",
            "* * * * 8", "*/0 * * * *", "5-2 * * * *", "a * * * *", "1/2/3 * * * *",
        ] {
            #expect(throws: CronSchedule.ParseError.self) { _ = try CronSchedule(expression) }
        }
    }
}
