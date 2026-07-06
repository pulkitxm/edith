import Foundation
import Testing

@testable import EdithKit

@Suite struct StandupScheduleTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let scheduled = 9 * 60 + 30

    @Test func notYetDueBeforeScheduledTime() {
        let now = date(2024, 1, 10, hour: 9, minute: 0)
        #expect(
            !StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: scheduled, lastRunDay: nil, calendar: utc))
    }

    @Test func dueOnceScheduledTimePasses() {
        let now = date(2024, 1, 10, hour: 9, minute: 31)
        #expect(
            StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: scheduled, lastRunDay: nil, calendar: utc))
    }

    @Test func notDueTwiceSameDay() {
        let now = date(2024, 1, 10, hour: 11, minute: 0)
        #expect(
            !StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: scheduled, lastRunDay: "2024-01-10",
                calendar: utc))
    }

    @Test func catchesUpOnWakeSameDay() {
        let now = date(2024, 1, 10, hour: 14, minute: 0)
        #expect(
            StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: scheduled, lastRunDay: "2024-01-09",
                calendar: utc))
    }

    @Test func catchesUpImmediatelyAtNextLaunchAfterFullyMissedDay() {
        let now = date(2024, 1, 10, hour: 7, minute: 0)
        #expect(
            StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: scheduled, lastRunDay: "2024-01-08",
                calendar: utc))
    }

    @Test func waitsForScheduledTimeWhenPreviousDayRan() {
        let now = date(2024, 1, 10, hour: 7, minute: 0)
        #expect(
            !StandupSchedule.isDue(
                now: now, scheduledMinutesFromMidnight: scheduled, lastRunDay: "2024-01-09",
                calendar: utc))
    }

    @Test func dayKeyFormatsAsYMD() {
        #expect(StandupSchedule.dayKey(date(2024, 3, 4, hour: 0), calendar: utc) == "2024-03-04")
    }
}
