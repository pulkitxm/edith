@testable import EdithKit
import Foundation
import Testing

@Suite struct CodeStatsScheduleTests {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String, _ zone: String = "UTC") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func manualNeverRuns() {
        let schedule = CodeStatsSchedule.manual
        #expect(
            schedule.nextRun(after: nil, calendar: calendar()) == nil
        )
        #expect(!schedule.isDue(lastRun: nil, now: date("2026-06-01 09:00"), calendar: calendar()))
    }

    @Test func aScheduleThatNeverRanWaitsForTheFirstExplicitRun() {
        let now = date("2026-06-01 09:30")
        let later = date("2026-06-09 03:00")
        for schedule in [CodeStatsSchedule.daily(hour: 3), .weekly(weekday: 2, hour: 3)] {
            #expect(schedule.nextRun(after: nil, calendar: calendar()) == nil)
            #expect(!schedule.isDue(lastRun: nil, now: now, calendar: calendar()))
            #expect(!schedule.isDue(lastRun: nil, now: later, calendar: calendar()))
        }
    }

    @Test func dailyRunsAtTheNextSlotAfterTheLastRun() {
        let schedule = CodeStatsSchedule.daily(hour: 9)
        let last = date("2026-06-01 09:05")
        #expect(
            schedule.nextRun(after: last, calendar: calendar())
                == date("2026-06-02 09:00"))
        #expect(!schedule.isDue(lastRun: last, now: date("2026-06-02 08:59"), calendar: calendar()))
        #expect(schedule.isDue(lastRun: last, now: date("2026-06-02 09:00"), calendar: calendar()))
    }

    @Test func weeklyRunsOnTheChosenWeekday() {
        let schedule = CodeStatsSchedule.weekly(weekday: 2, hour: 6)
        let last = date("2026-06-01 06:10")
        #expect(
            schedule.nextRun(after: last, calendar: calendar())
                == date("2026-06-08 06:00"))
        #expect(!schedule.isDue(lastRun: last, now: date("2026-06-07 23:00"), calendar: calendar()))
    }

    @Test func missedSlotsCatchUpOnceThenWaitForTheNextSlot() {
        let schedule = CodeStatsSchedule.daily(hour: 9)
        let last = date("2026-06-01 09:00")
        let reconnected = date("2026-06-04 15:00")
        #expect(schedule.isDue(lastRun: last, now: reconnected, calendar: calendar()))
        #expect(
            !schedule.isDue(
                lastRun: reconnected, now: date("2026-06-05 08:00"), calendar: calendar()))
        #expect(
            schedule.nextRun(after: reconnected, calendar: calendar())
                == date("2026-06-05 09:00"))
    }

    @Test func aSkippedDaylightSavingHourRunsAtTheNextValidTime() {
        let zone = "America/Los_Angeles"
        let schedule = CodeStatsSchedule.daily(hour: 2)
        let last = date("2026-03-07 02:00", zone)
        let skipped = schedule.nextRun(after: last, calendar: calendar(zone))
        #expect(skipped == date("2026-03-08 03:00", zone))
        let following = schedule.nextRun(after: skipped, calendar: calendar(zone))
        #expect(following == date("2026-03-09 02:00", zone))
    }

    @Test func aRepeatedDaylightSavingHourRunsOnce() throws {
        let zone = "America/Los_Angeles"
        let schedule = CodeStatsSchedule.daily(hour: 1)
        let last = date("2026-10-31 01:00", zone)
        let first = try #require(schedule.nextRun(after: last, calendar: calendar(zone)))
        #expect(first.timeIntervalSince(last) == 24 * 3_600)
        let next = try #require(
            schedule.nextRun(after: first, calendar: calendar(zone)))
        #expect(next.timeIntervalSince(first) == 25 * 3_600)
    }
}

@Suite struct CodeStatsStorageTests {
    private func probe(
        mounted: Bool = true, entry: CodeStatsFileEntry = .directory, writable: Bool = true
    ) -> CodeStatsFileProbe {
        CodeStatsFileProbe(
            volume: { CodeStatsFileProbe.externalVolume(of: $0) }, isMounted: { _ in mounted },
            entry: { _ in entry }, isWritable: { _ in writable }, freeBytes: { _ in 42 })
    }

    @Test func anEmptyPathIsNotConfigured() {
        #expect(CodeStatsStorageEvaluator.status(for: nil, probe: probe()) == .notConfigured)
        #expect(CodeStatsStorageEvaluator.status(for: "  ", probe: probe()) == .notConfigured)
    }

    @Test func anUnmountedVolumeIsDisconnectedNeverMissing() {
        let status = CodeStatsStorageEvaluator.status(
            for: "/Volumes/Archive/GitHub", probe: probe(mounted: false, entry: .absent))
        #expect(status == .volumeDisconnected(volumeName: "Archive"))
    }

    @Test func folderStatesMapToTheirStatus() {
        let path = "/Users/someone/GitHub"
        #expect(
            CodeStatsStorageEvaluator.status(for: path, probe: probe(entry: .absent)) == .missing)
        #expect(
            CodeStatsStorageEvaluator.status(for: path, probe: probe(entry: .file)) == .notDirectory
        )
        #expect(
            CodeStatsStorageEvaluator.status(for: path, probe: probe(writable: false))
                == .notWritable)
        #expect(
            CodeStatsStorageEvaluator.status(for: path, probe: probe()) == .ready(freeBytes: 42))
        #expect(
            CodeStatsStorageEvaluator.status(
                for: "/Users/someone/GitHub", probe: probe(mounted: false)
            )
            .isReady)
    }

    @Test func theLiveProbeReportsAnAbsentVolumeWithoutCreatingIt() {
        let name = "EdithCodeStatsMissing-\(UUID().uuidString)"
        let status = CodeStatsStorageEvaluator.status(for: "/Volumes/\(name)/mirror")
        #expect(status == .volumeDisconnected(volumeName: name))
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(name)"))
    }

    @Test func theLiveProbeSeesMissingReadOnlyAndReadyFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "code-stats-storage-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(CodeStatsStorageEvaluator.status(for: root.path) == .missing)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(CodeStatsStorageEvaluator.status(for: root.path).isReady)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        #expect(CodeStatsStorageEvaluator.status(for: root.path) == .notWritable)
        #expect(CodeStatsFileProbe.externalVolume(of: root.path) == nil)
    }
}
