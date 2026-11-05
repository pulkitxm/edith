import EdithExtensionCore
import Foundation
import Testing

@Suite struct DateFilterTests {
    private func calendar(
        _ zone: String = "UTC", firstWeekday: Int = 2, identifier: Calendar.Identifier = .gregorian
    ) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func moment(
        _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar
    ) throws -> Date {
        try #require(
            calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    private func day(_ string: String) throws -> DateFilterDay {
        try #require(DateFilterDay(string))
    }

    private func strings(
        _ selection: DateFilterSelection, _ now: Date, _ calendar: Calendar
    ) -> String? {
        selection.range(now: now, calendar: calendar).map { "\($0.firstString) \($0.lastString)" }
    }

    @Test func everyPresetResolvesAgainstAFixedDate() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let expected: [(DateFilterPreset, String?)] = [
            (.today, "2026-11-05 2026-11-05"),
            (.yesterday, "2026-11-04 2026-11-04"),
            (.thisWeek, "2026-11-02 2026-11-05"),
            (.lastWeek, "2026-10-26 2026-11-01"),
            (.last7, "2026-10-30 2026-11-05"),
            (.last14, "2026-10-23 2026-11-05"),
            (.thisMonth, "2026-11-01 2026-11-05"),
            (.lastMonth, "2026-10-01 2026-10-31"),
            (.last30, "2026-10-07 2026-11-05"),
            (.last90, "2026-08-08 2026-11-05"),
            (.thisYear, "2026-01-01 2026-11-05"),
            (.lastYear, "2025-01-01 2025-12-31"),
            (.last12Months, "2025-11-06 2026-11-05"),
            (.allTime, nil),
        ]
        #expect(expected.map(\.0) == DateFilterPreset.allCases)
        for (preset, range) in expected {
            #expect(strings(.preset(preset), now, calendar) == range, "\(preset)")
        }
        #expect(DateFilterSelection.preset(.allTime).interval(now: now, calendar: calendar) == nil)
    }

    @Test func standardWordingAndGroupingStayFixed() {
        #expect(
            DateFilterPreset.quick.map(\.chipTitle) == [
                "Today", "7 days", "30 days", "90 days", "All time",
            ])
        #expect(DateFilterPreset.groups.flatMap { $0 } == DateFilterPreset.allCases)
        #expect(
            DateFilterPreset.allCases.map(\.title) == [
                "Today", "Yesterday", "This week", "Last week", "Last 7 days", "Last 14 days",
                "This month", "Last month", "Last 30 days", "Last 90 days", "This year",
                "Last year", "Last 12 months", "All time",
            ])
    }

    @Test func weekBoundariesFollowTheFirstWeekday() throws {
        let cases: [(Int, String, String)] = [
            (1, "2026-11-01 2026-11-05", "2026-10-25 2026-10-31"),
            (2, "2026-11-02 2026-11-05", "2026-10-26 2026-11-01"),
            (7, "2026-10-31 2026-11-05", "2026-10-24 2026-10-30"),
        ]
        for (firstWeekday, thisWeek, lastWeek) in cases {
            let calendar = calendar(firstWeekday: firstWeekday)
            let now = try moment(2026, 11, 5, calendar: calendar)
            #expect(strings(.preset(.thisWeek), now, calendar) == thisWeek)
            #expect(strings(.preset(.lastWeek), now, calendar) == lastWeek)
        }
        let sunday = calendar(firstWeekday: 1)
        let onFirstDay = try moment(2026, 11, 1, calendar: sunday)
        #expect(strings(.preset(.thisWeek), onFirstDay, sunday) == "2026-11-01 2026-11-01")
        #expect(strings(.preset(.lastWeek), onFirstDay, sunday) == "2026-10-25 2026-10-31")
    }

    @Test func intervalsAreHalfOpenAcrossDaylightSavingChanges() throws {
        let newYork = calendar("America/New_York")
        let spring = try moment(2026, 3, 8, calendar: newYork)
        let short = try #require(
            DateFilterSelection.preset(.today).interval(now: spring, calendar: newYork))
        #expect(short.duration == 23 * 3_600)
        #expect(newYork.component(.hour, from: short.start) == 0)
        #expect(newYork.component(.hour, from: short.end) == 0)
        let autumn = try moment(2026, 11, 1, calendar: newYork)
        let long = try #require(
            DateFilterSelection.preset(.today).interval(now: autumn, calendar: newYork))
        #expect(long.duration == 25 * 3_600)
        let spanning = try #require(
            DateFilterSelection.preset(.last7)
                .interval(now: try moment(2026, 3, 10, calendar: newYork), calendar: newYork))
        #expect(spanning.duration == 7 * 86_400 - 3_600)
        #expect(newYork.component(.hour, from: spanning.start) == 0)
        #expect(newYork.component(.day, from: spanning.start) == 4)
    }

    @Test func intervalStartsAtTheFirstValidMomentWhenMidnightIsSkipped() throws {
        let havana = calendar("America/Havana")
        let gapDay = try moment(2026, 3, 8, calendar: havana)
        let interval = try #require(
            DateFilterSelection.preset(.today).interval(now: gapDay, calendar: havana))
        #expect(interval.duration == 23 * 3_600)
        #expect(havana.component(.hour, from: interval.start) == 1)
        #expect(havana.component(.day, from: interval.start) == 8)
        #expect(DateFilterDay(date: interval.start, calendar: havana).string == "2026-03-08")
    }

    @Test func resolutionRespectsTheCalendarTimeZone() throws {
        let instant = Date(timeIntervalSince1970: 1_793_750_400)
        let tokyo = strings(.preset(.today), instant, calendar("Asia/Tokyo"))
        let losAngeles = strings(.preset(.today), instant, calendar("America/Los_Angeles"))
        #expect(tokyo != losAngeles)
    }

    @Test func nonGregorianCalendarsStillProduceCivilDayStrings() throws {
        let buddhist = calendar(identifier: .buddhist)
        let now = Date(timeIntervalSince1970: 1_793_880_000)
        #expect(strings(.preset(.today), now, buddhist)?.hasPrefix("2026-11-05") == true)
        #expect(strings(.preset(.thisWeek), now, buddhist) == "2026-11-02 2026-11-05")
        #expect(strings(.preset(.thisYear), now, buddhist) == "2026-01-01 2026-11-05")
    }

    @Test func monthEndsAndLeapDaysResolveCorrectly() throws {
        let calendar = calendar()
        let march = try moment(2026, 3, 31, calendar: calendar)
        #expect(strings(.preset(.lastMonth), march, calendar) == "2026-02-01 2026-02-28")
        let leapMarch = try moment(2028, 3, 31, calendar: calendar)
        #expect(strings(.preset(.lastMonth), leapMarch, calendar) == "2028-02-01 2028-02-29")
        let january = try moment(2026, 1, 31, calendar: calendar)
        #expect(strings(.preset(.lastMonth), january, calendar) == "2025-12-01 2025-12-31")
        let leapDay = try moment(2028, 2, 29, calendar: calendar)
        #expect(strings(.preset(.thisMonth), leapDay, calendar) == "2028-02-01 2028-02-29")
        #expect(strings(.preset(.last12Months), leapDay, calendar) == "2027-03-01 2028-02-29")
        #expect(strings(.preset(.lastYear), leapDay, calendar) == "2027-01-01 2027-12-31")
        let afterLeap = try moment(2029, 2, 28, calendar: calendar)
        #expect(strings(.preset(.last12Months), afterLeap, calendar) == "2028-02-29 2029-02-28")
        let month = try #require(DateFilterMonth("2028-02"))
        #expect(month.range.days == 29)
        #expect(DateFilterDay("2028-02-29") != nil)
        #expect(DateFilterDay("2026-02-29") == nil)
        #expect(DateFilterDay("2100-02-29") == nil)
        #expect(DateFilterDay("2000-02-29") != nil)
    }

    @Test func civilDayArithmeticMatchesFoundation() throws {
        let calendar = calendar()
        var cursor = try moment(1999, 12, 25, hour: 0, calendar: calendar)
        var value = DateFilterDay(date: cursor, calendar: calendar)
        for _ in 0..<12_000 {
            #expect(value == DateFilterDay(date: cursor, calendar: calendar))
            #expect(value.weekday == calendar.component(.weekday, from: cursor))
            #expect(value.date(calendar: calendar) == cursor)
            cursor = try #require(calendar.date(byAdding: .day, value: 1, to: cursor))
            value = value.advanced(by: 1)
        }
    }

    @Test func dayPresetsStepThroughSingleDays() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let today = DateFilterSelection.preset(.today)
        #expect(!today.canStepForward(now: now, calendar: calendar))
        #expect(today.stepped(by: 1, now: now, calendar: calendar) == today)
        let yesterday = today.stepped(by: -1, now: now, calendar: calendar)
        #expect(yesterday == .preset(.yesterday))
        #expect(yesterday.canStepForward(now: now, calendar: calendar))
        let earlier = yesterday.stepped(by: -1, now: now, calendar: calendar)
        #expect(strings(earlier, now, calendar) == "2026-11-03 2026-11-03")
        #expect(earlier.periodLabel(now: now, calendar: calendar) == "Tue 3 Nov 2026")
        #expect(earlier.stepped(by: 1, now: now, calendar: calendar) == yesterday)
    }

    @Test func weekPresetsStepByWholeWeeks() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let thisWeek = DateFilterSelection.preset(.thisWeek)
        let lastWeek = thisWeek.stepped(by: -1, now: now, calendar: calendar)
        #expect(lastWeek == .preset(.lastWeek))
        let older = lastWeek.stepped(by: -1, now: now, calendar: calendar)
        #expect(strings(older, now, calendar) == "2026-10-19 2026-10-25")
        #expect(older.stepped(by: 1, now: now, calendar: calendar) == lastWeek)
        #expect(lastWeek.stepped(by: 1, now: now, calendar: calendar) == thisWeek)
        #expect(!thisWeek.canStepForward(now: now, calendar: calendar))
    }

    @Test func monthsStepAcrossMonthEndsAndYears() throws {
        let calendar = calendar()
        let now = try moment(2026, 1, 31, calendar: calendar)
        let thisMonth = DateFilterSelection.preset(.thisMonth)
        let lastMonth = thisMonth.stepped(by: -1, now: now, calendar: calendar)
        #expect(lastMonth == .preset(.lastMonth))
        #expect(strings(lastMonth, now, calendar) == "2025-12-01 2025-12-31")
        let november = lastMonth.stepped(by: -1, now: now, calendar: calendar)
        #expect(november == .month(try #require(DateFilterMonth("2025-11"))))
        #expect(strings(november, now, calendar) == "2025-11-01 2025-11-30")
        #expect(november.stepped(by: 1, now: now, calendar: calendar) == lastMonth)
        #expect(lastMonth.stepped(by: 1, now: now, calendar: calendar) == thisMonth)
        let february = DateFilterSelection.month(try #require(DateFilterMonth("2024-02")))
        #expect(
            strings(february.stepped(by: 1, now: now, calendar: calendar), now, calendar)
                == "2024-03-01 2024-03-31")
    }

    @Test func yearsStepThroughLeapYears() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let thisYear = DateFilterSelection.preset(.thisYear)
        let lastYear = thisYear.stepped(by: -1, now: now, calendar: calendar)
        #expect(lastYear == .preset(.lastYear))
        let leap = lastYear.stepped(by: -1, now: now, calendar: calendar)
        #expect(strings(leap, now, calendar) == "2024-01-01 2024-12-31")
        #expect(leap.title(calendar: calendar) == "2024")
        #expect(leap.periodLabel(now: now, calendar: calendar) == "2024")
        #expect(leap.stepped(by: 1, now: now, calendar: calendar) == lastYear)
        #expect(lastYear.stepped(by: 1, now: now, calendar: calendar) == thisYear)
        #expect(!thisYear.canStepForward(now: now, calendar: calendar))
    }

    @Test func fixedLengthRangesStepByTheirLengthAndStopAtToday() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let last7 = DateFilterSelection.preset(.last7)
        let earlier = last7.stepped(by: -1, now: now, calendar: calendar)
        #expect(strings(earlier, now, calendar) == "2026-10-23 2026-10-29")
        #expect(earlier.stepped(by: 1, now: now, calendar: calendar) == last7)
        #expect(!last7.canStepForward(now: now, calendar: calendar))
        let custom = DateFilterSelection.custom(
            DateFilterRange(try day("2026-10-29"), try day("2026-11-03")))
        #expect(custom.canStepForward(now: now, calendar: calendar))
        let clamped = custom.stepped(by: 1, now: now, calendar: calendar)
        #expect(strings(clamped, now, calendar) == "2026-10-31 2026-11-05")
        #expect(!clamped.canStepForward(now: now, calendar: calendar))
        let year = DateFilterSelection.preset(.last12Months)
        let previous = year.stepped(by: -1, now: now, calendar: calendar)
        #expect(strings(previous, now, calendar) == "2024-11-06 2025-11-05")
        #expect(previous.stepped(by: 1, now: now, calendar: calendar) == year)
    }

    @Test func customRangesCoveringACalendarUnitStepByThatUnit() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let february = DateFilterSelection.custom(
            DateFilterRange(try day("2026-02-01"), try day("2026-02-28")))
        #expect(
            strings(february.stepped(by: 1, now: now, calendar: calendar), now, calendar)
                == "2026-03-01 2026-03-31")
        let wholeYear = DateFilterSelection.custom(
            DateFilterRange(try day("2023-01-01"), try day("2023-12-31")))
        #expect(
            strings(wholeYear.stepped(by: 1, now: now, calendar: calendar), now, calendar)
                == "2024-01-01 2024-12-31")
    }

    @Test func steppingHonorsTheEarliestDataDate() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let earliest = try day("2026-11-01")
        #expect(
            DateFilterSelection.preset(.thisMonth)
                .canStepBackward(earliest: try day("2026-10-15"), now: now, calendar: calendar))
        #expect(
            !DateFilterSelection.preset(.thisMonth)
                .canStepBackward(earliest: earliest, now: now, calendar: calendar))
        #expect(
            DateFilterSelection.preset(.today)
                .canStepBackward(earliest: earliest, now: now, calendar: calendar))
    }

    @Test func allTimeDoesNotStep() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        let all = DateFilterSelection.preset(.allTime)
        #expect(!all.isSteppable)
        #expect(!all.canStepForward(now: now, calendar: calendar))
        #expect(!all.canStepBackward(now: now, calendar: calendar))
        #expect(all.stepped(by: -1, now: now, calendar: calendar) == all)
        #expect(all.periodLabel(now: now, calendar: calendar) == "All time")
    }

    @Test func periodLabelsReadNaturally() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        func label(_ selection: DateFilterSelection) -> String {
            selection.periodLabel(now: now, calendar: calendar)
        }
        #expect(label(.preset(.today)) == "Today")
        #expect(label(.preset(.yesterday)) == "Yesterday")
        #expect(label(.preset(.thisMonth)) == "November 2026")
        #expect(label(.preset(.lastMonth)) == "October 2026")
        #expect(label(.preset(.thisYear)) == "2026")
        #expect(label(.preset(.lastYear)) == "2025")
        #expect(label(.preset(.last7)) == "30 Oct to 5 Nov 2026")
        #expect(label(.preset(.thisWeek)) == "2 Nov to 5 Nov 2026")
        #expect(
            label(.custom(DateFilterRange(try day("2026-10-03"), try day("2026-10-12"))))
                == "3 Oct to 12 Oct 2026")
        #expect(
            label(.custom(DateFilterRange(try day("2025-12-28"), try day("2026-01-03"))))
                == "28 Dec 2025 to 3 Jan 2026")
        #expect(
            DateFilterSelection.month(try #require(DateFilterMonth("2024-02")))
                .title(calendar: calendar) == "February 2024")
    }

    @Test func canonicalNamesAnyRangeThatMatchesAPreset() throws {
        let calendar = calendar()
        let now = try moment(2026, 11, 5, calendar: calendar)
        func custom(_ first: String, _ last: String) throws -> DateFilterSelection {
            .custom(DateFilterRange(try day(first), try day(last)))
        }
        #expect(
            try custom("2026-11-05", "2026-11-05").canonical(now: now, calendar: calendar)
                == .preset(.today))
        #expect(
            try custom("2026-10-30", "2026-11-05").canonical(now: now, calendar: calendar)
                == .preset(.last7))
        #expect(
            try custom("2026-10-01", "2026-10-31").canonical(now: now, calendar: calendar)
                == .preset(.lastMonth))
        #expect(
            try custom("2026-08-01", "2026-08-31").canonical(now: now, calendar: calendar)
                == .month(try #require(DateFilterMonth("2026-08"))))
        #expect(
            DateFilterSelection.month(try #require(DateFilterMonth("2026-11")))
                .canonical(now: now, calendar: calendar) == .preset(.thisMonth))
        let plain = try custom("2026-10-03", "2026-10-12")
        #expect(plain.canonical(now: now, calendar: calendar) == plain)
        #expect(
            DateFilterSelection.preset(.thisWeek).canonical(now: now, calendar: calendar)
                == .preset(.thisWeek))
    }

    @Test func selectionsRoundTripThroughStrings() throws {
        var selections = DateFilterPreset.allCases.map { DateFilterSelection.preset($0) }
        selections.append(.month(try #require(DateFilterMonth("2024-02"))))
        selections.append(.custom(DateFilterRange(try day("2024-02-29"), try day("2026-11-05"))))
        for selection in selections {
            #expect(DateFilterSelection(rawValue: selection.rawValue) == selection)
        }
        #expect(DateFilterSelection.preset(.allTime).rawValue == "all")
        #expect(
            DateFilterSelection(rawValue: "custom:2026-10-12~2026-10-03")
                == .custom(DateFilterRange(try day("2026-10-03"), try day("2026-10-12"))))
        for invalid in [
            "", "soon", "month:2026-13", "month:2026", "custom:2026-10-03",
            "custom:2026-02-30~2026-03-01", "custom:2026-10-03~2026-10-04~2026-10-05",
        ] {
            #expect(DateFilterSelection(rawValue: invalid) == nil, "\(invalid)")
        }
    }

    @Test func draftBuildsARangeFromTwoClicks() throws {
        var draft = DateFilterDraft(range: nil, earliest: nil, latest: try day("2026-11-05"))
        #expect(!draft.canApply)
        draft.select(try day("2026-10-03"))
        #expect(!draft.canApply)
        #expect(draft.editing == .end)
        draft.select(try day("2026-10-12"))
        #expect(draft.canApply)
        #expect(draft.range == DateFilterRange(try day("2026-10-03"), try day("2026-10-12")))
        #expect(draft.editing == .start)
    }

    @Test func draftSwapsAnEndBeforeTheStartAndAllowsOneDay() throws {
        var draft = DateFilterDraft(range: nil, earliest: nil, latest: try day("2026-11-05"))
        draft.select(try day("2026-10-12"))
        draft.select(try day("2026-10-03"))
        #expect(draft.range == DateFilterRange(try day("2026-10-03"), try day("2026-10-12")))
        var single = DateFilterDraft(range: nil, earliest: nil, latest: try day("2026-11-05"))
        single.select(try day("2026-10-03"))
        single.select(try day("2026-10-03"))
        #expect(single.range?.days == 1)
    }

    @Test func draftClearsAnEndThatTheNewStartPasses() throws {
        var draft = DateFilterDraft(
            range: DateFilterRange(try day("2026-10-03"), try day("2026-10-12")), earliest: nil,
            latest: try day("2026-11-05"))
        draft.select(try day("2026-10-05"))
        #expect(draft.range == DateFilterRange(try day("2026-10-05"), try day("2026-10-12")))
        draft.edit(.start)
        draft.select(try day("2026-10-20"))
        #expect(draft.end == nil)
        #expect(!draft.canApply)
    }

    @Test func draftEditsAChosenEndpoint() throws {
        var draft = DateFilterDraft(
            range: DateFilterRange(try day("2026-10-03"), try day("2026-10-12")), earliest: nil,
            latest: try day("2026-11-05"))
        draft.edit(.end)
        #expect(draft.cursor == (try day("2026-10-12")))
        draft.select(try day("2026-10-20"))
        #expect(draft.range == DateFilterRange(try day("2026-10-03"), try day("2026-10-20")))
    }

    @Test func draftRejectsDaysOutsideItsBoundsAndClampsTheInitialRange() throws {
        let earliest = try day("2026-10-10")
        let latest = try day("2026-11-05")
        var draft = DateFilterDraft(
            range: DateFilterRange(try day("2026-09-01"), try day("2026-12-01")),
            earliest: earliest, latest: latest)
        #expect(draft.range == DateFilterRange(earliest, latest))
        #expect(!draft.allows(try day("2026-10-09")))
        #expect(!draft.allows(try day("2026-11-06")))
        let before = draft
        draft.select(try day("2026-10-09"))
        draft.select(try day("2026-11-06"))
        #expect(draft == before)
    }

    @Test func draftCursorMovesWithinBoundsAndFollowsTheMonth() throws {
        var draft = DateFilterDraft(
            range: nil, earliest: try day("2026-10-30"), latest: try day("2026-11-05"))
        #expect(draft.cursor == (try day("2026-11-05")))
        draft.moveCursor(byDays: 1)
        #expect(draft.cursor == (try day("2026-11-05")))
        draft.moveCursor(byDays: -7)
        #expect(draft.cursor == (try day("2026-10-30")))
        #expect(draft.visibleMonth == (try #require(DateFilterMonth("2026-10"))))
        draft.moveCursor(byDays: -1)
        #expect(draft.cursor == (try day("2026-10-30")))
        #expect(!draft.canShowPreviousMonth)
        #expect(draft.canShowNextMonth)
        draft.selectCursor()
        #expect(draft.start == (try day("2026-10-30")))
    }

    @Test func draftMonthMovesKeepTheDayWithinShorterMonths() throws {
        var draft = DateFilterDraft(range: nil, earliest: nil, latest: try day("2026-03-31"))
        draft.moveCursor(byMonths: -1)
        #expect(draft.cursor == (try day("2026-02-28")))
        draft.showMonth(offset: -1)
        #expect(draft.visibleMonth == (try #require(DateFilterMonth("2026-01"))))
        #expect(draft.cursor == (try day("2026-01-28")))
    }

    @Test func draftGridAlwaysShowsSixWeeksFromTheFirstWeekday() throws {
        let draft = DateFilterDraft(range: nil, earliest: nil, latest: try day("2026-11-05"))
        for firstWeekday in 1...7 {
            let days = draft.gridDays(firstWeekday: firstWeekday)
            #expect(days.count == 42)
            #expect(days[0].weekday == firstWeekday)
            #expect(days.contains(try day("2026-11-01")))
            #expect(days.contains(try day("2026-11-30")))
        }
    }
}
