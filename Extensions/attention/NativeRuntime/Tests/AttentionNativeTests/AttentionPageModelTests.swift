import EdithExtensionCore
import Foundation
import Testing

@testable import AttentionNative
@MainActor
@Suite struct AttentionPageModelTests {
    @Test func setupExplainsWhyTrackingCannotBeginWithoutASource() {
        #expect(
            AttentionPageModel.setupBlocker(applicationTracking: false, browserTracking: false)
                != nil)
        #expect(
            AttentionPageModel.setupBlocker(applicationTracking: true, browserTracking: false)
                == nil)
        #expect(
            AttentionPageModel.setupBlocker(applicationTracking: false, browserTracking: true)
                == nil)
    }

    @Test func idleSetupPollsLessOftenThanLiveTracking() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.reload()
        await model.waitForReload()
        if model.needsSetup {
            #expect(model.refreshInterval == .seconds(60))
        }
    }

    @Test func openingBreakdownDirectlyRetainsEntityIconSourcesAcrossTabs() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try fixture.repository.append(
            AttentionEvent(
                startedAt: Date().addingTimeInterval(-120), duration: 60, source: .application,
                appName: "Sample Notes", bundleID: "test.notes"))
        let model = AttentionPageModel(repository: fixture.repository)
        model.section = .breakdown
        model.reload()
        await model.waitForReload()
        let entity = try #require(model.summary.entities.first)
        #expect(entity.bundleID == "test.notes")
        #expect(
            model.summary.dimensions.first { $0.key == AttentionDimension.entity }?.rows.first?
                .entityIDs == [entity.id])
        model.section = .timeline
        await model.waitForReload()
        #expect(model.summary.entities.first?.bundleID == "test.notes")
    }

    @Test func refreshAndRangeChangesPreserveTheSelectedSectionAndFilters() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try fixture.repository.append(
            AttentionEvent(
                startedAt: Date().addingTimeInterval(-120), duration: 60,
                source: .application, appName: "Xcode", bundleID: "com.apple.dt.Xcode"))
        let model = AttentionPageModel(repository: fixture.repository)
        model.reload()
        await model.waitForReload()
        for section in [AttentionPageSection.overview, .timeline, .breakdown, .agents, .focus] {
            model.section = section
            await model.waitForReload()
            model.toggle(level: .veryProductive)
            let filter = model.levelFilter
            model.reload()
            await model.waitForReload()
            #expect(model.section == section)
            #expect(model.levelFilter == filter)
            model.select(.preset(.last7))
            await model.waitForReload()
            #expect(model.section == section)
            #expect(model.levelFilter == filter)
            model.select(.preset(.today))
            await model.waitForReload()
            #expect(model.section == section)
        }
    }

    @Test func rapidRangeAndTabChangesPublishOnlyTheLatestSelection() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let now = Date()
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-3_600)
        for (date, title) in [
            (now.addingTimeInterval(-200 * 86_400), "Old note"), (yesterday, "Recent note"),
        ] {
            try fixture.repository.append(
                AttentionEvent(
                    startedAt: date, duration: 60, source: .application, appName: "Writing",
                    bundleID: "app.writing", windowTitle: title))
        }
        let model = AttentionPageModel(repository: fixture.repository)
        model.select(.preset(.last7))
        await model.waitForReload()
        model.select(.preset(.allTime))
        model.select(.preset(.last90))
        model.select(.preset(.yesterday))
        model.section = .breakdown
        await model.waitForReload()
        #expect(model.period.selection == .preset(.yesterday))
        #expect(model.summary.from == Calendar.current.startOfDay(for: yesterday))
        #expect(model.summary.activeDuration == 60)
        #expect(
            model.summary.dimensions.first { $0.key == AttentionDimension.title }?.rows.map(\.key)
                == ["Recent note"])
        #expect(!model.pending)
        #expect(model.errorMessage == nil)
        model.select(.preset(.today))
        await model.waitForReload()
        #expect(model.summary.activeDuration == 0)
        #expect(model.summary.dimensions.isEmpty)
    }

    @Test func missingTabReloadsRetainedDataWhenCategorizationChanges() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try fixture.repository.append(
            AttentionEvent(
                startedAt: Date().addingTimeInterval(-120), duration: 60, source: .application,
                appName: "Writing", bundleID: "app.writing"))
        let model = AttentionPageModel(repository: fixture.repository)
        model.reload()
        await model.waitForReload()
        let entity = try #require(model.summary.entities.first)
        var settings = fixture.repository.loadSettings()
        settings.assign(entityID: entity.id, categoryID: "focus")
        try fixture.repository.saveSettings(settings)
        model.section = .breakdown
        await model.waitForReload()
        #expect(model.summary.entities.first?.category.id == "focus")
        #expect(model.summary.productiveDuration == 60)
        #expect(
            model.summary.dimensions.first { $0.key == AttentionDimension.entity }?
                .rows.first?.categories["focus"] == 60)
        model.section = .overview
        #expect(!model.pending)
    }

    @Test func allTimeCoversEveryRecordedDayWithoutComparisonsOrStepping() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let now = Date()
        let first = now.addingTimeInterval(-500 * 86_400)
        for date in [first, now.addingTimeInterval(-120)] {
            try fixture.repository.append(
                AttentionEvent(
                    startedAt: date, duration: 60, source: .application,
                    appName: "Writing", bundleID: "app.writing"))
        }
        let model = AttentionPageModel(repository: fixture.repository)
        model.select(.preset(.allTime))
        await model.waitForReload()
        #expect(model.summary.activeDuration == 120)
        #expect(model.summary.from == Calendar.current.startOfDay(for: first))
        #expect(model.summary.previous == nil)
        #expect(model.period.title() == "All time")
        #expect(model.period.comparePeriod() == nil)
        #expect(!model.period.selection.isSteppable)
        #expect(model.refreshInterval == .seconds(120))
        model.select(.preset(.last90))
        await model.waitForReload()
        #expect(model.summary.activeDuration == 60)
    }

    @Test func emptyAllTimeIsBoundedToToday() async {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.select(.preset(.allTime))
        await model.waitForReload()
        #expect(model.summary.from == Calendar.current.startOfDay(for: Date()))
        #expect(model.summary.activeDuration == 0)
        #expect(model.errorMessage == nil)
    }

    @Test func dayRibbonRangeStaysValidForBlocksFromAnotherDay() {
        let day = DateInterval(start: Date(timeIntervalSince1970: 1_790_000_000), duration: 86_400)
        let later = [day.end.addingTimeInterval(7_200), day.end.addingTimeInterval(9_000)]
        let earlier = [day.start.addingTimeInterval(-9_000), day.start.addingTimeInterval(-60)]
        let spanning = [day.start.addingTimeInterval(-600), day.end.addingTimeInterval(600)]
        for dates in [later, earlier, spanning] {
            let range = AttentionDayRibbon.visibleRange(dates, day: day)
            #expect(range.lowerBound >= day.start)
            #expect(range.upperBound <= day.end)
        }
        let inside = [day.start.addingTimeInterval(36_000), day.start.addingTimeInterval(40_000)]
        let range = AttentionDayRibbon.visibleRange(inside + later, day: day)
        #expect(range.lowerBound < inside[0])
        #expect(range.upperBound > inside[1])
    }

    @Test func pristineStoreShowsGuidedSetupWithoutActivity() async {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.reload()
        await model.waitForReload()
        #expect(model.loaded)
        #expect(model.needsSetup)
        #expect(model.hasActivity == false)
        #expect(model.summary.entities.isEmpty)
        #expect(model.summary.spans.isEmpty)
    }

    @Test func completingSetupPersistsRealSourceChoices() async {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.completeSetup(applicationTracking: true, browserTracking: false)
        await model.waitForReload()
        let settings = fixture.repository.loadSettings()
        #expect(settings.isEnabled)
        #expect(settings.trackingEnabled)
        #expect(settings.browserTrackingEnabled == false)
        #expect(model.settings.trackingEnabled)
        #expect(model.needsSetup == false)
        #expect(model.hasActivity == false)
    }

    @Test func masterSwitchStopsCollectionWithoutLosingSourceChoices() async {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.completeSetup(applicationTracking: true, browserTracking: true)
        model.setAttentionEnabled(false)
        await model.waitForReload()
        let settings = fixture.repository.loadSettings()
        #expect(settings.isEnabled == false)
        #expect(settings.trackingEnabled)
        #expect(settings.browserTrackingEnabled)
        #expect(model.settings.isEnabled == false)
        #expect(model.browserConnected == false)
    }

    @Test func categoryMenuReclassifiesExistingEntity() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let now = Date()
        try fixture.repository.append(
            AttentionEvent(
                startedAt: now.addingTimeInterval(-120), duration: 60,
                source: .application, appName: "Writing", bundleID: "com.example.Writing"))
        let model = AttentionPageModel(repository: fixture.repository)
        model.select(.preset(.last7))
        await model.waitForReload()
        let entity = try #require(model.summary.entities.first)
        #expect(entity.name == "Writing")
        model.assign(entity: entity, to: "focus")
        await model.waitForReload()
        #expect(model.summary.productiveDuration == 60)
    }

    @Test func tabsLoadTheirOwnPartsAndFiltersRunOffTheMainPath() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        try fixture.repository.saveSettings(
            AttentionSettings(isEnabled: true, trackingEnabled: true))
        for (offset, app) in [
            ("com.apple.dt.Xcode", "Xcode"), ("com.tinyspeck.slackmacgap", "Slack"),
        ]
        .enumerated() {
            try fixture.repository.append(
                AttentionEvent(
                    startedAt: now.addingTimeInterval(Double(-600 + offset * 300)),
                    duration: Double(240 - offset * 30),
                    source: .application, appName: app.1, bundleID: app.0))
        }
        let model = AttentionPageModel(repository: fixture.repository)
        model.setPeriod(AttentionPeriod(.preset(.today), now: now))
        model.reload()
        await model.waitForReload()
        #expect(model.timeline.isEmpty)
        #expect(!model.dayRibbon.isEmpty)
        let entities = model.summary.entities
        let interval = DateInterval(start: model.summary.from, end: model.summary.to)
        model.section = .timeline
        #expect(model.pending)
        await model.waitForReload()
        #expect(!model.pending)
        #expect(model.timeline.first?.blocks.count == 2)
        #expect(model.summary.entities == entities)
        #expect(model.summary.from == interval.start)
        #expect(model.summary.to == interval.end)
        let spans = model.summary.spans
        model.section = .breakdown
        await model.waitForReload()
        #expect(model.summary.entities == entities)
        #expect(model.summary.spans == spans)
        #expect(model.timeline.first?.blocks.count == 2)
        #expect(model.summary.dimensions.contains { $0.key == AttentionDimension.entity })
        let dimensions = model.summary.dimensions
        model.section = .agents
        await model.waitForReload()
        #expect(model.summary.dimensions == dimensions)
        #expect(model.summary.entities == entities)
        model.section = .overview
        #expect(!model.pending)
        model.section = .timeline
        #expect(!model.pending)
        model.searchText = "slack"
        try await Task.sleep(for: .milliseconds(400))
        await model.waitForReload()
        #expect(model.timeline.first?.blocks.map(\.name) == ["Slack"])
        model.toggle(level: .veryProductive)
        await model.waitForReload()
        #expect(model.timeline.allSatisfy { $0.blocks.isEmpty })
        #expect(!model.hasActivity)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 15) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func periodsCoverTheirDaysAndEndAtTheCurrentDay() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let today = AttentionPeriod(.preset(.today), now: now, calendar: calendar)
        #expect(today.start == calendar.startOfDay(for: now))
        #expect(today.interval(now: now).end == now)
        #expect(today.isSingleDay)
        #expect(today.isCurrent(now: now))
        let week = AttentionPeriod(.preset(.last7), now: now, calendar: calendar)
        #expect(week.days(calendar: calendar) == 7)
        let lastMonth = AttentionPeriod(.preset(.lastMonth), now: now, calendar: calendar)
        #expect(calendar.component(.day, from: lastMonth.start) == 1)
        #expect(!lastMonth.isCurrent(now: now))
        #expect(AttentionPeriod(.preset(.last90), now: now, calendar: calendar).showsSpans == false)
    }

    private func previous(
        _ selection: DateFilterSelection, now: Date, calendar: Calendar
    ) -> DateInterval? {
        let period = AttentionPeriod(selection, now: now, calendar: calendar)
        let interval = period.interval(now: now)
        return AttentionSummaryRequest(
            from: interval.start, to: interval.end,
            comparePeriod: period.comparePeriod(now: now, calendar: calendar)
        ).previousInterval
    }

    @Test func thisWeekComparesAgainstTheSameElapsedDaysLastWeek() throws {
        let calendar = utcCalendar()
        let now = date(2026, 11, 5)
        let prior = try #require(previous(.preset(.thisWeek), now: now, calendar: calendar))
        #expect(prior.start == date(2026, 10, 26, hour: 0))
        #expect(prior.end == date(2026, 10, 29))
        let period = AttentionPeriod(.preset(.thisWeek), now: now, calendar: calendar)
        #expect(period.interval(now: now).duration == prior.duration)
    }

    @Test func thisMonthComparesAgainstTheFirstDaysOfLastMonth() throws {
        let calendar = utcCalendar()
        let prior = try #require(
            previous(.preset(.thisMonth), now: date(2026, 11, 5), calendar: calendar))
        #expect(prior.start == date(2026, 10, 1, hour: 0))
        #expect(prior.end == date(2026, 10, 5))
        let shortMonth = try #require(
            previous(.preset(.thisMonth), now: date(2026, 3, 5), calendar: calendar))
        #expect(shortMonth.start == date(2026, 2, 1, hour: 0))
        #expect(shortMonth.end == date(2026, 2, 5))
    }

    @Test func wholePeriodsCompareAgainstTheSameNumberOfDaysBefore() throws {
        let calendar = utcCalendar()
        let now = date(2026, 11, 5)
        let today = try #require(previous(.preset(.today), now: now, calendar: calendar))
        #expect(today.start == date(2026, 11, 4, hour: 0))
        #expect(today.end == date(2026, 11, 4))
        let lastWeek = try #require(previous(.preset(.lastWeek), now: now, calendar: calendar))
        #expect(lastWeek.start == date(2026, 10, 19, hour: 0))
        #expect(lastWeek.end == date(2026, 10, 26, hour: 0))
        let days = try #require(previous(.preset(.last7), now: now, calendar: calendar))
        #expect(days.start == date(2026, 10, 23, hour: 0))
        let last = AttentionPeriod(.preset(.lastMonth), now: now, calendar: calendar)
        let month = try #require(previous(.preset(.lastMonth), now: now, calendar: calendar))
        #expect(month.duration == last.end.timeIntervalSince(last.start))
    }

    @Test func comparisonIsDroppedWhenThePriorPeriodPassesRetention() {
        let calendar = utcCalendar()
        let now = date(2026, 11, 5)
        for preset in [DateFilterPreset.last12Months, .lastYear, .allTime] {
            #expect(
                AttentionPeriod(.preset(preset), now: now, calendar: calendar)
                    .comparePeriod(now: now, calendar: calendar) == nil, "\(preset)")
        }
        #expect(
            AttentionPeriod(.preset(.last90), now: now, calendar: calendar)
                .comparePeriod(now: now, calendar: calendar) != nil)
    }

    @Test func periodsPastRetentionSayWhereTheyActuallyStart() {
        let calendar = utcCalendar()
        let now = date(2026, 11, 5)
        let note = AttentionPeriod(.preset(.lastYear), now: now, calendar: calendar)
            .retentionNote(now: now, calendar: calendar)
        #expect(note == "Attention keeps 365 days, so this starts 5 Nov 2025")
        for preset in [DateFilterPreset.today, .last90, .thisYear, .last12Months] {
            #expect(
                AttentionPeriod(.preset(preset), now: now, calendar: calendar)
                    .retentionNote(now: now, calendar: calendar) == nil, "\(preset)")
        }
        var allTime = AttentionPeriod(.preset(.allTime), now: now, calendar: calendar)
        #expect(allTime.retentionNote(now: now, calendar: calendar) == nil)
        allTime.start = AttentionRetention.cutoff(now: now)
        #expect(allTime.retentionNote(now: now, calendar: calendar) != nil)
    }

    @Test func dayAndHourWindowsKeepOnlyMatchingTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 8))!
        let event = AttentionEvent(
            startedAt: monday, duration: 3 * 3_600, source: .application, appName: "Xcode",
            signals: AttentionSignals(keys: 300))
        let work = AttentionTimeWindow(startHour: 9, endHour: 10).apply([event], calendar: calendar)
        #expect(work.count == 1)
        #expect(work.first?.duration == 3_600)
        #expect(work.first?.signals?.keys == 100)
        let weekends = AttentionTimeWindow(weekdays: AttentionTimeWindow.weekends)
        #expect(weekends.apply([event], calendar: calendar).isEmpty)
        let overnight = AttentionTimeWindow(startHour: 22, endHour: 9)
        #expect(overnight.apply([event], calendar: calendar).first?.duration == 3_600)
    }

    @Test func timelineIconsUseApplicationBundlesAndWebsiteFavicons() {
        let now = Date()
        let application = AttentionEvent(
            startedAt: now, duration: 30, source: .application, appName: "Music",
            bundleID: "com.apple.Music")
        let website = AttentionEvent(
            startedAt: now, duration: 30, source: .browser, domain: "meet.google.com",
            faviconURL: "https://meet.google.com/favicon.ico")

        #expect(
            AttentionEventIconDescriptor(event: application)
                == .application(bundleID: "com.apple.Music"))
        #expect(
            AttentionEventIconDescriptor(event: website)
                == .website(URL(string: "https://meet.google.com/favicon.ico")))
    }

    @Test func timelineIconsRejectLocalFaviconSchemesAndKeepSourceFallbacks() {
        let now = Date()
        let website = AttentionEvent(
            startedAt: now, duration: 30, source: .browser, domain: "settings",
            faviconURL: "file:///tmp/favicon.ico")
        let media = AttentionEvent(
            startedAt: now, duration: 30, source: .media,
            media: AttentionMedia(
                title: "Track", service: "Music", kind: "audio", playing: true))
        let manual = AttentionEvent(startedAt: now, duration: 30, source: .manual)

        #expect(AttentionEventIconDescriptor(event: website) == .website(nil))
        #expect(AttentionEventIconDescriptor(event: media) == .icon(.music))
        #expect(AttentionEventIconDescriptor(event: manual) == .icon(.cursor))
    }

    @Test func summaryIconsPreferFaviconsThenApplicationBundles() {
        let category = AttentionCatalog.categories[0]
        let website = AttentionEntity(
            id: "github", name: "github.com", category: category, source: .browser,
            duration: 30, bundleID: "com.google.Chrome",
            faviconURL: "https://github.com/favicon.ico")
        let application = AttentionEntity(
            id: "edith", name: "Edith", category: category, source: .application,
            duration: 30, bundleID: "com.pulkit.edith")

        #expect(
            AttentionEventIconDescriptor(entity: website)
                == .website(URL(string: "https://github.com/favicon.ico")))
        #expect(
            AttentionEventIconDescriptor(entity: application)
                == .application(bundleID: "com.pulkit.edith"))
    }

    @Test func filtersReachEverySectionFromOneFilteredSummary() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        var settings = AttentionSettings(isEnabled: true, trackingEnabled: true)
        settings.rules = [
            AttentionIdentityRule(
                name: "Feed", categoryID: "social", bundleIDs: ["test.feed"],
                productivity: .veryDistracting, sphere: .personal)
        ]
        try fixture.repository.saveSettings(settings)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-7_200)
        for (offset, app) in [("test.editor", "Sample Editor"), ("test.feed", "Sample Feed")]
            .enumerated()
        {
            try fixture.repository.append(
                AttentionEvent(
                    startedAt: start.addingTimeInterval(Double(offset) * 900),
                    duration: Double(600 - offset * 300), source: .application,
                    appName: app.1, bundleID: app.0, windowTitle: app.1 + " window"))
        }
        let model = AttentionPageModel(repository: fixture.repository)
        model.select(.preset(.last7))
        await model.waitForReload()
        #expect(model.summary.activeDuration == 900)
        #expect(model.activity == .idle)
        model.toggle(level: .veryDistracting)
        #expect(model.activity == .updating)
        await model.waitForReload()
        #expect(model.activity == .idle)
        for section in [AttentionPageSection.overview, .timeline, .breakdown, .agents, .focus] {
            model.section = section
            await model.waitForReload()
            #expect(model.summary.activeDuration == 300)
            #expect(model.summary.unmatchedDuration == 600)
            #expect(model.summary.entities.allSatisfy { $0.bundleID == "test.feed" })
            #expect(model.summary.categories.map(\.category.id) == ["social"])
        }
        model.section = .breakdown
        await model.waitForReload()
        #expect(model.breakdown.total == 300)
        model.section = .timeline
        await model.waitForReload()
        #expect(
            model.timeline.flatMap(\.blocks).allSatisfy { $0.categoryID == "social" })
        model.clearFilters()
        model.section = .overview
        model.searchText = "editor"
        #expect(model.activity == .updating)
        try await Task.sleep(for: .milliseconds(400))
        await model.waitForReload()
        #expect(model.summary.activeDuration == 600)
        #expect(model.summary.entities.map(\.bundleID) == ["test.editor"])
        model.clearFilters()
        await model.waitForReload()
        #expect(model.summary.activeDuration == 900)
        #expect(!model.hasFilters)
    }

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-attention-page-\(UUID().uuidString)")
        return Fixture(root: root, repository: AttentionRepository(root: root))
    }

    private struct Fixture {
        let root: URL
        let repository: AttentionRepository

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
