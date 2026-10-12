import EdithExtensionSupport
import Foundation
import Testing
@testable import TimeLapseExtension

@Suite @MainActor
struct TimeLapseSurfaceTests {
    @Test func ContentSourcesAndHiddenFieldsApplyToActualRecorderState() throws {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        recorder.recording = true; recorder.frames = 60; recorder.bytes = 1024
        recorder.startedAt = Date(timeIntervalSince1970: 100)
        let session = TimeLapseSession(settings: .init(), width: 1920, height: 1080)
        let recording = TimeLapseRecording(
            session: session, directory: URL(fileURLWithPath: "/synthetic/recording"))
        var tile = SurfaceTile(.ability("timeLapse"))
        let snapshot = TimeLapseSurface.snapshot(
            recorder, recordings: [recording], tile: tile, now: Date(timeIntervalSince1970: 110))
        #expect(snapshot.metrics.first { $0.id == "elapsed" }?.value == "10 s")
        #expect(snapshot.actions.map(\.id) == ["stop"])
        #expect(snapshot.rows.first?.actions.first?.id == "reveal:" + session.id.uuidString)
        #expect(snapshot.rows.first?.sourceID == ScreenRecordingMode.standard.rawValue)
        #expect(snapshot.sources.map(\.id) == ScreenRecordingMode.allCases.map(\.rawValue))
        tile.contentKinds = ["recordings"]
        tile.sourceIDs = [ScreenRecordingMode.timeLapse.rawValue]
        let selected = TimeLapseSurface.snapshot(recorder, recordings: [recording], tile: tile)
        #expect(selected.actions.isEmpty && selected.rows.isEmpty)
        #expect(selected.metrics.map(\.id) == ["recordings"])
        tile = .init(.ability("timeLapse")); tile.hiddenFields = ["frames", "size"]
        let filtered = SurfaceCommandService.project(snapshot, tile: tile)
        #expect(!filtered.metrics.contains { ["frames", "size"].contains($0.id) })
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "timeLapse")
    }
}
