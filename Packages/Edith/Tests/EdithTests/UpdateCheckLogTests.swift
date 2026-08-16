import EdithKit
import Foundation
import Testing

@Suite struct UpdateCheckLogTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-checks-\(UUID().uuidString).json")
    }

    private func record(
        _ offset: TimeInterval, kind: UpdateCheckRecord.Kind = .automatic,
        outcome: UpdateCheckRecord.Outcome = .upToDate
    ) -> UpdateCheckRecord {
        UpdateCheckRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000 + offset), kind: kind,
            outcome: outcome)
    }

    @Test func loadReturnsEmptyWhenNoFileExists() {
        #expect(UpdateCheckLog.load(from: tempURL()).isEmpty)
    }

    @Test func appendRoundTripsThroughDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        UpdateCheckLog.append(record(0, kind: .manual, outcome: .updateFound), to: url)

        let loaded = UpdateCheckLog.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded[0].kind == .manual)
        #expect(loaded[0].outcome == .updateFound)
    }

    @Test func newestRecordSortsFirst() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        UpdateCheckLog.append(record(0), to: url)
        UpdateCheckLog.append(record(600), to: url)
        UpdateCheckLog.append(record(300), to: url)

        let dates = UpdateCheckLog.load(from: url).map(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func historyIsCappedAtTheLimit() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        for index in 0..<(UpdateCheckLog.limit + 25) {
            UpdateCheckLog.append(record(TimeInterval(index)), to: url)
        }

        #expect(UpdateCheckLog.load(from: url).count == UpdateCheckLog.limit)
    }

    @Test func countsOnlyTheRequestedKind() {
        let records = [
            record(0, kind: .automatic), record(1, kind: .manual), record(2, kind: .automatic),
        ]
        #expect(UpdateCheckLog.count(of: .automatic, in: records) == 2)
        #expect(UpdateCheckLog.count(of: .manual, in: records) == 1)
    }

    @Test func clearRemovesEveryRecord() {
        let url = tempURL()
        UpdateCheckLog.append(record(0), to: url)
        UpdateCheckLog.clear(at: url)
        #expect(UpdateCheckLog.load(from: url).isEmpty)
    }

    @Test func corruptFileDegradesToEmpty() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not json".utf8).write(to: url)
        #expect(UpdateCheckLog.load(from: url).isEmpty)
    }

    @Test func summaryDescribesEachOutcome() {
        #expect(record(0, outcome: .upToDate).summary == "Up to date")
        #expect(
            UpdateCheckRecord(
                date: Date(), kind: .manual, outcome: .updateFound, version: "1.2.3"
            ).summary == "Found 1.2.3")
        #expect(
            UpdateCheckRecord(
                date: Date(), kind: .manual, outcome: .failed, detail: "offline"
            ).summary == "offline")
    }

    @Test func nearestIntervalSnapsToAChoice() {
        #expect(UpdateCheckInterval.nearest(to: 3_600).seconds == 3_600)
        #expect(UpdateCheckInterval.nearest(to: 80_000).seconds == 86_400)
        #expect(UpdateCheckInterval.nearest(to: 0).seconds == 3_600)
        #expect(UpdateCheckInterval.nearest(to: 9_999_999).seconds == 604_800)
    }

    @Test func everyIntervalChoiceIsUnique() {
        let seconds = UpdateCheckInterval.choices.map(\.seconds)
        #expect(Set(seconds).count == seconds.count)
        #expect(seconds == seconds.sorted())
    }

    @Test func presetsAreRecognised() {
        #expect(UpdateCheckInterval.isPreset(86_400))
        #expect(!UpdateCheckInterval.isPreset(5_400))
        #expect(!UpdateCheckInterval.isPreset(UpdateCheckInterval.customTag))
    }

    @Test func clampRaisesValuesBelowSparklesFloor() {
        #expect(UpdateCheckInterval.clamp(0) == UpdateCheckInterval.minimumSeconds)
        #expect(UpdateCheckInterval.clamp(60) == UpdateCheckInterval.minimumSeconds)
        #expect(UpdateCheckInterval.clamp(-500) == UpdateCheckInterval.minimumSeconds)
        #expect(UpdateCheckInterval.clamp(3_599) == UpdateCheckInterval.minimumSeconds)
    }

    @Test func clampKeepsValuesInRangeAndCapsTheTop() {
        #expect(UpdateCheckInterval.clamp(5_400) == 5_400)
        #expect(UpdateCheckInterval.clamp(3_600) == 3_600)
        #expect(
            UpdateCheckInterval.clamp(99_999_999) == UpdateCheckInterval.maximumSeconds)
    }

    @Test func clampRejectsNonFiniteInput() {
        #expect(UpdateCheckInterval.clamp(.nan) == UpdateCheckInterval.fallback.seconds)
        #expect(UpdateCheckInterval.clamp(.infinity) == UpdateCheckInterval.fallback.seconds)
    }

    @Test func describeUsesPresetLabelsWhenItCan() {
        #expect(UpdateCheckInterval.describe(3_600) == "Every hour")
        #expect(UpdateCheckInterval.describe(86_400) == "Every day")
    }

    @Test func describeBreaksCustomValuesIntoUnits() {
        #expect(UpdateCheckInterval.describe(5_400) == "Every 1h 30m")
        #expect(UpdateCheckInterval.describe(90_000) == "Every 1d 1h")
        #expect(UpdateCheckInterval.describe(7_200) == "Every 2h")
        #expect(UpdateCheckInterval.describe(172_800) == "Every 2d")
    }

    @Test func clampNoticeExplainsARaiseToTheFloor() {
        let notice = UpdateCheckInterval.clampNotice(
            entered: 1, applied: UpdateCheckInterval.clamp(1))
        #expect(notice?.contains("3600") == true)
    }

    @Test func clampNoticeExplainsACapAtTheCeiling() {
        let notice = UpdateCheckInterval.clampNotice(
            entered: 99_999_999, applied: UpdateCheckInterval.clamp(99_999_999))
        #expect(notice?.contains("Capped") == true)
    }

    @Test func clampNoticeIsSilentWhenNothingChanged() {
        #expect(UpdateCheckInterval.clampNotice(entered: 5_400, applied: 5_400) == nil)
        #expect(UpdateCheckInterval.clampNotice(entered: 3_600, applied: 3_600) == nil)
    }

    @Test func valuesClampingOntoAPresetStillReportTheChange() {
        let applied = UpdateCheckInterval.clamp(60)
        #expect(applied == 3_600)
        #expect(UpdateCheckInterval.isPreset(applied))
        #expect(UpdateCheckInterval.clampNotice(entered: 60, applied: applied) != nil)
    }

    @Test func customTagIsNeverMistakenForARealInterval() {
        #expect(UpdateCheckInterval.customTag < UpdateCheckInterval.minimumSeconds)
        #expect(
            !UpdateCheckInterval.choices.contains {
                $0.seconds == UpdateCheckInterval.customTag
            })
    }
}
