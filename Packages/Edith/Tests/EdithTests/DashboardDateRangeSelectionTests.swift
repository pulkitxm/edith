import Foundation
import Testing

@testable import Edith

@Suite struct DashboardDateRangeSelectionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        var components = DateComponents()
        let parts = value.split(separator: "-").compactMap { Int($0) }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    @Test func normalizesAndClampsInitialRange() {
        let bounds = date("2026-05-15")...date("2026-08-31")
        let selection = DashboardDateRangeSelection(
            from: date("2026-09-12"), to: date("2026-04-01"), bounds: bounds,
            calendar: calendar)

        #expect(selection.from == bounds.lowerBound)
        #expect(selection.to == bounds.upperBound)
    }

    @Test func selectsACompleteRangeWithoutRecomputingBetweenClicks() {
        let bounds = date("2026-05-15")...date("2026-08-31")
        var selection = DashboardDateRangeSelection(
            from: bounds.lowerBound, to: bounds.upperBound, bounds: bounds, calendar: calendar)

        selection.select(date("2026-08-05"), bounds: bounds, calendar: calendar)
        #expect(selection.from == date("2026-08-05"))
        #expect(selection.to == date("2026-08-05"))
        #expect(selection.choosingEnd)

        selection.select(date("2026-08-22"), bounds: bounds, calendar: calendar)
        #expect(selection.from == date("2026-08-05"))
        #expect(selection.to == date("2026-08-22"))
        #expect(!selection.choosingEnd)
    }

    @Test func shortcutsRespectAvailableData() {
        let bounds = date("2026-08-20")...date("2026-08-31")
        var selection = DashboardDateRangeSelection(
            from: bounds.lowerBound, to: bounds.lowerBound, bounds: bounds, calendar: calendar)

        selection.setTrailing(days: 30, bounds: bounds, calendar: calendar)
        #expect(selection.from == bounds.lowerBound)
        #expect(selection.to == bounds.upperBound)

        selection.setMonthToDate(bounds: bounds, calendar: calendar)
        #expect(selection.from == bounds.lowerBound)
        #expect(selection.to == bounds.upperBound)
    }
}
