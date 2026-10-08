import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct AttentionPageModelTests {
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
            model.select(.last7)
            await model.waitForReload()
            #expect(model.section == section)
            #expect(model.levelFilter == filter)
            model.select(.today)
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
        model.select(.last7)
        await model.waitForReload()
        model.select(.allTime)
        model.select(.last90)
        model.select(.yesterday)
        model.section = .breakdown
        await model.waitForReload()
        #expect(model.period.preset == .yesterday)
        #expect(model.summary.from == Calendar.current.startOfDay(for: yesterday))
        #expect(model.summary.activeDuration == 60)
        #expect(
            model.summary.dimensions.first { $0.key == AttentionDimension.title }?.rows.map(\.key)
                == ["Recent note"])
        #expect(!model.pending)
        #expect(model.errorMessage == nil)
        model.select(.today)
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
        model.select(.allTime)
        await model.waitForReload()
        #expect(model.summary.activeDuration == 120)
        #expect(model.summary.from == Calendar.current.startOfDay(for: first))
        #expect(model.summary.previous == nil)
        #expect(model.period.title() == "All time")
        #expect(model.period.comparePeriod == nil)
        #expect(!model.canStepBackward)
        #expect(!model.canStepForward)
        #expect(model.refreshInterval == .seconds(120))
        let period = model.period
        model.step(-1)
        #expect(model.period == period)
        model.select(.last90)
        await model.waitForReload()
        #expect(model.summary.activeDuration == 60)
    }

    @Test func emptyAllTimeIsBoundedToToday() async {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.select(.allTime)
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
        model.select(.last7)
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
        model.setPeriod(AttentionPeriod(.today, now: now))
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
        #expect(model.timeline.first?.blocks.isEmpty == true)
    }

    @Test func presetsCoverTheirDaysAndStepByTheirLength() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let today = AttentionPeriod(.today, now: now, calendar: calendar)
        #expect(today.start == calendar.startOfDay(for: now))
        #expect(today.interval(now: now).end == now)
        #expect(today.isSingleDay)
        let yesterday = today.shifted(by: -1, calendar: calendar)
        #expect(yesterday.days(calendar: calendar) == 1)
        #expect(yesterday.end == today.start)
        let week = AttentionPeriod(.last7, now: now, calendar: calendar)
        #expect(week.days(calendar: calendar) == 7)
        #expect(week.shifted(by: -1, calendar: calendar).end == week.start)
        let month = AttentionPeriod(.lastMonth, now: now, calendar: calendar)
        let earlier = month.shifted(by: -1, calendar: calendar)
        #expect(calendar.component(.day, from: earlier.start) == 1)
        #expect(earlier.end == month.start)
        let custom = AttentionPeriod.custom(
            from: now, to: now.addingTimeInterval(-2 * 86_400), calendar: calendar)
        #expect(custom.days(calendar: calendar) == 3)
        #expect(custom.preset == .custom)
        #expect(AttentionPeriod(.last90, now: now, calendar: calendar).showsSpans == false)
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
        #expect(AttentionEventIconDescriptor(event: media) == .symbol("music.note"))
        #expect(AttentionEventIconDescriptor(event: manual) == .symbol("hand.tap"))
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
