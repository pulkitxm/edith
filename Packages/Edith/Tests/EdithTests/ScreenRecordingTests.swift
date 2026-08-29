import Foundation
import Testing

@testable import EdithKit

@Suite struct ScreenRecordingTests {
    @Test func timelineNormalizesCutsAndProducesKeptRanges() {
        let document = ScreenRecordingEditDocument(
            trimStart: 1, trimEnd: 9,
            cuts: [
                ScreenRecordingRange(start: 2, end: 4),
                ScreenRecordingRange(start: 3.5, end: 5),
                ScreenRecordingRange(start: 7, end: 8),
            ])

        #expect(
            document.keptRanges(duration: 10) == [
                ScreenRecordingRange(start: 1, end: 2),
                ScreenRecordingRange(start: 5, end: 7),
                ScreenRecordingRange(start: 8, end: 9),
            ])
    }

    @Test func smoothingKeepsTimesAndCalmsAbruptMovement() throws {
        let points = [
            ScreenRecordingPoint(time: 0, x: 0, y: 0),
            ScreenRecordingPoint(time: 1, x: 1, y: 1),
            ScreenRecordingPoint(time: 2, x: 0, y: 0),
        ]
        let smoothed = ScreenRecordingTimeline.smoothed(points, amount: 0.8)

        #expect(smoothed.map(\.time) == points.map(\.time))
        #expect(try #require(smoothed.first).x > 0)
        #expect(try #require(smoothed.last).x > 0)
    }

    @Test func automaticZoomsIgnoreTheStopTail() {
        let zooms = ScreenRecordingTimeline.automaticZooms(
            clicks: [
                ScreenRecordingClick(time: 1, x: 0.2, y: 0.3),
                ScreenRecordingClick(time: 9.5, x: 0.8, y: 0.9),
            ], duration: 10)

        #expect(zooms.count == 1)
        #expect(zooms.first?.start == 0.75)
        #expect(zooms.first?.scale == 1.8)
    }

    @Test func editDocumentBoundsUnsafeValues() {
        let document = ScreenRecordingEditDocument(
            trimStart: -4, trimEnd: 20, pointerSmoothing: 4,
            pointerScale: 9, padding: -2, systemAudioVolume: 5,
            microphoneVolume: -1)
        let normalized = document.normalized(duration: 8)

        #expect(normalized.trimStart == 0)
        #expect(normalized.trimEnd == 8)
        #expect(normalized.pointerSmoothing == 1)
        #expect(normalized.pointerScale == 3)
        #expect(normalized.padding == 0)
        #expect(normalized.systemAudioVolume == 2)
        #expect(normalized.microphoneVolume == 0)
    }

    @Test func exportPresetsRoundTripThroughSharedSettings() throws {
        let suite = "ScreenRecordingPresetStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preset = ScreenRecordingExportPreset(
            name: "Review", format: .mp4, width: 1440, frameRate: 24, quality: 0.75)

        ScreenRecordingPresetStore.save([preset], defaults: defaults)

        #expect(ScreenRecordingPresetStore.load(defaults: defaults) == [preset])
    }

    @Test func statusStoreDefaultsToIdleAndDecodesRuntimeState() throws {
        let suite = "ScreenRecordingStatusStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ScreenRecordingStatusStore.load(defaults: defaults).state == .idle)
        let status = ScreenRecordingStatus(
            state: .paused, source: .window, elapsedSeconds: 12.5,
            takeID: UUID())
        defaults.set(
            try JSONEncoder().encode(status),
            forKey: AppStorageKeys.Capture.recordingStatus)

        #expect(ScreenRecordingStatusStore.load(defaults: defaults) == status)
    }

    @Test func unfinishedTakeSurvivesAndCompletedLibraryIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unfinished = try ScreenRecordingLibrary.makeTake(source: .area, in: directory)
        try Data([1]).write(
            to: ScreenRecordingLibrary.masterURL(for: unfinished.id, in: directory))
        for index in 0..<(ScreenRecordingLibrary.maximumCount + 2) {
            var take = try ScreenRecordingLibrary.makeTake(
                source: .display, in: directory,
                now: Date(timeIntervalSince1970: Double(index)))
            try Data([1]).write(
                to: ScreenRecordingLibrary.masterURL(for: take.id, in: directory))
            take.completedAt = Date(timeIntervalSince1970: Double(index))
            try ScreenRecordingLibrary.update(take, in: directory)
        }

        ScreenRecordingLibrary.prune(in: directory, keeping: [unfinished.id])
        let takes = ScreenRecordingLibrary.load(from: directory)
        #expect(takes.contains { $0.id == unfinished.id })
        #expect(takes.filter { $0.completedAt != nil }.count == ScreenRecordingLibrary.maximumCount)
    }
}
