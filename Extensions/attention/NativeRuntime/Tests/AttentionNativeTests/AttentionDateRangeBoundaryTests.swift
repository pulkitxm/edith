import EdithExtensionCore
import Foundation
import Testing

@testable import AttentionNative

@MainActor
@Suite(.serialized) struct AttentionDateRangeBoundaryTests {
    private struct Sample {
        let start: Date
        let duration: TimeInterval
    }

    private func fixture() throws -> (AttentionRepository, URL, [Sample]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-boundaries-\(UUID().uuidString)")
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var samples: [Sample] = []
        for offset in 0...364 {
            let day = try #require(calendar.date(byAdding: .day, value: -offset, to: today))
            let start = day.addingTimeInterval(1)
            let duration = TimeInterval(1 + offset)
            samples.append(Sample(start: start, duration: duration))
            try repository.append(
                AttentionEvent(
                    id: "boundary-\(offset)", startedAt: start, duration: duration,
                    source: .application, appName: "Writing", bundleID: "app.writing",
                    windowTitle: "Day \(offset)"))
        }
        return (repository, root, samples)
    }

    private func manualSum(_ samples: [Sample], from start: Date, to end: Date) -> TimeInterval {
        samples.filter { $0.start >= start && $0.start < end }.reduce(0) { $0 + $1.duration }
    }

    private func expectedBounds(_ preset: DateFilterPreset) throws -> (Date, Date) {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, from base: Date = today) throws -> Date {
            try #require(calendar.date(byAdding: .day, value: offset, to: base))
        }
        let tomorrow = try day(1)
        let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
        let month = try #require(calendar.dateInterval(of: .month, for: now))
        let year = try #require(calendar.dateInterval(of: .year, for: now))
        switch preset {
        case .today: return (today, tomorrow)
        case .yesterday: return (try day(-1), today)
        case .thisWeek: return (week.start, tomorrow)
        case .lastWeek: return (try day(-7, from: week.start), week.start)
        case .last7: return (try day(-6), tomorrow)
        case .last14: return (try day(-13), tomorrow)
        case .thisMonth: return (month.start, tomorrow)
        case .lastMonth:
            return (
                try #require(calendar.date(byAdding: .month, value: -1, to: month.start)),
                month.start
            )
        case .last30: return (try day(-29), tomorrow)
        case .last90: return (try day(-89), tomorrow)
        case .thisYear: return (year.start, tomorrow)
        case .lastYear:
            return (
                try #require(calendar.date(byAdding: .year, value: -1, to: year.start)),
                year.start
            )
        default: return (Date.distantPast, tomorrow)
        }
    }

    @Test(arguments: [
        DateFilterPreset.today, .yesterday, .thisWeek, .lastWeek, .last7, .last14, .thisMonth,
        .lastMonth, .last30, .last90, .thisYear, .lastYear, .allTime,
    ])
    func presetTotalsEqualAManualSum(preset: DateFilterPreset) async throws {
        let (repository, root, samples) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AttentionPageModel(repository: repository)
        model.select(.preset(preset))
        model.reload()
        await model.waitForReload()
        let (start, end) = try expectedBounds(preset)
        #expect(model.summary.activeDuration == manualSum(samples, from: start, to: end))
        await model.shutdown()
    }

    @Test func aRangeWithNoActivitySaysSoInsteadOfWaitingForTracking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
        try repository.append(
            AttentionEvent(
                id: "recent", startedAt: Date().addingTimeInterval(-3 * 86_400), duration: 60,
                source: .application, appName: "Writing", bundleID: "app.writing"))
        let model = AttentionPageModel(repository: repository)
        model.select(.preset(.lastYear))
        model.reload()
        await model.waitForReload()
        #expect(!model.hasActivity)
        #expect(model.showsEmptyPeriod)
        model.select(.preset(.today))
        model.reload()
        await model.waitForReload()
        #expect(!model.showsEmptyPeriod)
        await model.shutdown()
    }

    @Test func customRangeTotalsEqualAManualSum() async throws {
        let (repository, root, samples) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = try #require(calendar.date(byAdding: .day, value: -20, to: today))
        let last = try #require(calendar.date(byAdding: .day, value: -11, to: today))
        let model = AttentionPageModel(repository: repository)
        model.select(
            .custom(
                DateFilterRange(
                    DateFilterDay(date: first, calendar: calendar),
                    DateFilterDay(date: last, calendar: calendar))))
        await model.waitForReload()
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: last))
        #expect(model.summary.activeDuration == manualSum(samples, from: first, to: end))
        await model.shutdown()
    }

    @Test func thisWeekComparesToTheSameDaysLastWeekNotTheWholeWeek() async throws {
        let (repository, root, samples) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = Calendar.current
        let now = Date()
        let model = AttentionPageModel(repository: repository)
        model.select(.preset(.thisWeek))
        await model.waitForReload()
        let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
        let start = try #require(calendar.date(byAdding: .day, value: -7, to: week.start))
        let shift = week.start.timeIntervalSince(start)
        let previous = try #require(model.summary.previous)
        let expected = manualSum(samples, from: start, to: now.addingTimeInterval(-shift))
        #expect(previous.active == expected)
        await model.shutdown()
    }
}
