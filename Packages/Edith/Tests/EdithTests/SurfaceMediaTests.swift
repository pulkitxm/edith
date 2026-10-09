import EdithCore
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct SurfaceMediaTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)
    private func app(
        _ object: UInt32 = 41, pid: Int32 = 700, bundle: String = "sample.music",
        volume: Double = 0.4
    ) -> AudioMixerAppRecord {
        .init(objectID: object, pid: pid, bundleID: bundle, name: "Sample player", volume: volume)
    }
    @Test func volumeControlsRejectReusedOrChangedProcesses() throws {
        let original = app()
        #expect(try original.target.match(in: [original]) == original)
        for replacement in [app(42), app(pid: 701), app(bundle: "sample.other")] {
            #expect(throws: AudioMixerSelectionError.self) {
                try original.target.match(in: [replacement])
            }
        }
        #expect(!AudioMixerTarget(objectID: 0, pid: 700, bundleID: "sample").valid)
    }
    @Test func runtimeRequestsKeepTheExactTargetAndRejectInvalidValues() throws {
        let request = AudioMixerRuntimeRequest(
            request: .volume, volume: 0.4,
            deadline: now.addingTimeInterval(8), target: app().target)
        let decoded = try #require(AudioMixerRuntimeRequest(payload: request.payload))
        #expect(decoded.target == app().target)
        #expect(decoded.volume == 0.4)
        #expect(decoded.isLive(at: now))
        #expect(!decoded.isLive(at: now.addingTimeInterval(9)))
        for badVolume in [Double.nan, .infinity, -1, 2] {
            var payload = request.payload
            payload[AudioMixerIPC.volumeKey] = badVolume
            #expect(AudioMixerRuntimeRequest(payload: payload) == nil)
        }
        var payload = request.payload
        payload[AudioMixerIPC.targetKey] = "{}"
        #expect(AudioMixerRuntimeRequest(payload: payload) == nil)
        #expect(app(volume: .nan).percent == 100)
        #expect(app(volume: 200).percent == 100)
    }
    @Test func mixerSourcesAndControlsStayIndependentPerWidget() throws {
        let records = [app(), app(42, bundle: "sample.browser", volume: 0), app(43)]
        let snapshot = AudioMixerListSnapshot(apps: records, changed: false)
        var tile = SurfaceTile(.ability("audioMixer"))
        let all = SurfaceMediaProjection.audio(snapshot, tile: tile, now: now)
        #expect(all.rows.count == 3)
        #expect(all.sources.count == 2)
        #expect(Set(all.rows.map(\.id)).count == 3)
        tile.sourceIDs = ["sample.browser"]
        let selected = SurfaceMediaProjection.audio(snapshot, tile: tile, now: now)
        #expect(selected.rows.count == 1)
        #expect(selected.metrics.first?.value == "1")
        let row = try #require(selected.rows.first)
        #expect(row.volume?.target == records[1].target)
        #expect(row.actions.first?.action == .audioVolume(records[1].target, 1))
        tile.sourceIDs = []
        #expect(SurfaceMediaProjection.audio(snapshot, tile: tile).rows.isEmpty)
    }
    @Test func sampleMediaUsesTheSameSourceAndContentFilters() {
        var tile = SurfaceTile(.ability("audioMixer"))
        tile.sourceIDs = ["sample.browser"]
        let mixer = SurfaceSampleData.snapshot(tile)
        #expect(mixer.rows.count == 1)
        #expect(mixer.metrics.first?.value == "1")
        tile = SurfaceTile(.ability("timeLapse"))
        tile.sourceIDs = [ScreenRecordingMode.timeLapse.rawValue]
        let recorder = SurfaceSampleData.snapshot(tile)
        #expect(recorder.rows.isEmpty)
        #expect(!recorder.metrics.contains { $0.id == "state" })
        tile.sourceIDs = nil; tile.contentKinds = ["recordings"]
        #expect(SurfaceSampleData.snapshot(tile).rows.isEmpty)
    }
    @Test func anOlderReadCannotOverwriteACompletedAdjustment() async throws {
        let probe = SurfaceMediaReadProbe()
        let client = SurfaceExtensionClient(reader: { _ in await probe.read() })
        let tile = SurfaceTile(.ability("audioMixer"))
        let first = Task { try await client.snapshot(tile) }
        await probe.waitForFirst()
        await client.invalidate(tile.widget)
        let adjusted = try await client.snapshot(tile, force: true)
        #expect(adjusted.metrics.first?.value == "New")
        await probe.release()
        do {
            _ = try await first.value
            Issue.record("An invalidated media read completed successfully.")
        } catch is CancellationError {} catch {
            Issue.record(error)
        }
        let cached = try await client.snapshot(tile)
        #expect(cached.metrics.first?.value == "New")
        #expect(await probe.count == 2)
    }
    @Test func recorderStopIsBoundToItsCurrentLiveSession() {
        var status = SurfaceRecorderSnapshot()
        let id = UUID()
        status.sessionID = id; status.recording = true
        let request = SurfaceRecorderRequest(.stop, sessionID: id, now: now)
        #expect(status.permitsStop(request, now: now))
        #expect(!status.permitsStop(.init(.stop, sessionID: UUID(), now: now), now: now))
        #expect(!status.permitsStop(request, now: now.addingTimeInterval(9)))
        #expect(!status.permitsStop(.init(.stop, now: now), now: now))
        status.busy = true
        #expect(!status.permitsStop(request, now: now))
        status.busy = false; status.recording = false
        #expect(!status.permitsStop(request, now: now))
    }
    @Test func recorderCardsDistinguishUnknownBusyAndLiveStates() throws {
        let tile = SurfaceTile(.ability("timeLapse"))
        let unavailable = SurfaceMediaProjection.recorder(
            nil, library: .init(), tile: tile, now: now)
        #expect(!unavailable.metrics.contains { $0.id == "state" })
        #expect(unavailable.message?.contains("Open Screen Recorder") == true)
        var status = SurfaceRecorderSnapshot()
        status.sessionID = UUID(); status.recording = true
        status.startedAt = now.addingTimeInterval(-320); status.frames = 9600;
        status.bytes = 240_000_000
        let active = SurfaceMediaProjection.recorder(status, library: .init(), tile: tile, now: now)
        #expect(active.metrics.first { $0.id == "elapsed" }?.value == "5m 20s")
        let sessionID = try #require(status.sessionID)
        #expect(active.rows.first?.actions.first?.action == .stopRecording(sessionID))
        status.busy = true
        let finishing = SurfaceMediaProjection.recorder(
            status, library: .init(), tile: tile, now: now)
        #expect(finishing.metrics.first?.value == "Finishing")
        #expect(finishing.rows.first?.actions.isEmpty == true)
    }
    @Test func recordingModeAndContentFiltersDoNotExposeExcludedRows() {
        var settings = TimeLapseSettings(); settings.mode = .timeLapse
        var session = TimeLapseSession(settings: settings, width: 1920, height: 1080)
        session.endedAt = now
        let library = SurfaceRecordingLibrary(records: [
            .init(session: session, directory: URL(fileURLWithPath: "/tmp/sample"))
        ])
        var status = SurfaceRecorderSnapshot(); status.recording = true; status.sessionID = UUID()
        var tile = SurfaceTile(.ability("timeLapse"))
        tile.sourceIDs = [ScreenRecordingMode.timeLapse.rawValue]
        let filtered = SurfaceMediaProjection.recorder(
            status, library: library, tile: tile, now: now)
        #expect(filtered.rows.map(\.id) == [session.id.uuidString])
        #expect(!filtered.metrics.contains { $0.id == "state" })
        tile.contentKinds = ["active"]
        #expect(SurfaceMediaProjection.recorder(status, library: library, tile: tile).rows.isEmpty)
        tile.sourceIDs = []
        #expect(SurfaceMediaProjection.recorder(status, library: library, tile: tile).rows.isEmpty)
    }
    @Test @MainActor func readingRecorderStateDoesNotDiscoverCaptureSources() {
        guard #available(macOS 15.0, *) else { return }
        let recorder = TimeLapseRecorder()
        let before = recorder.sourceRevision
        let snapshot = recorder.surfaceSnapshot
        #expect(!snapshot.recording)
        #expect(snapshot.sessionID == nil)
        #expect(recorder.sourceRevision == before)
        #expect(
            recorder.displays.isEmpty && recorder.windows.isEmpty && recorder.microphones.isEmpty)
        #expect(!recorder.sourceLoad.isRunning)
    }
    @Test func recordingMetadataSkipsMalformedOversizedSymlinkedAndOverflowingSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ data: Data) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("session.json"))
            return directory
        }
        var session = TimeLapseSession(settings: .init(), width: 1920, height: 1080)
        session.endedAt = now
        let valid = try write("valid", JSONEncoder().encode(session))
        _ = try write("invalid", Data("{}".utf8))
        _ = try write("oversized", Data(repeating: 32, count: 262_145))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: valid)
        session.segments = [
            .init(file: "../outside.mov", kind: "video", frames: 1, startedAt: now, duration: 1)
        ]
        _ = try write("traversal", JSONEncoder().encode(session))
        session.segments = [
            .init(file: "one.mov", kind: "video", frames: .max, startedAt: now, duration: 1),
            .init(file: "two.mov", kind: "video", frames: .max, startedAt: now, duration: 1),
        ]
        _ = try write("overflow", JSONEncoder().encode(session))
        let library = try SurfaceRecordingLibrary.read(root: root)
        #expect(library.records.count == 1)
        #expect(
            library.records.first?.directory.resolvingSymlinksInPath().path
                == valid.resolvingSymlinksInPath().path)
        #expect(!library.truncated)
    }
    @Test func metadataEnumerationIsBoundedAndReportsItsLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<513 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sample-\(index)"),
                withIntermediateDirectories: true)
        }
        let library = try SurfaceRecordingLibrary.read(root: root)
        #expect(library.truncated)
        #expect(library.records.isEmpty)
    }
}

private actor SurfaceMediaReadProbe {
    private(set) var count = 0
    private var started: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func read() async -> SurfaceExtensionSnapshot {
        count += 1
        let first = count == 1
        if first {
            started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
        }
        return .init(metrics: [.init("volume", "Volume", first ? "Old" : "New")])
    }
    func waitForFirst() async {
        if count > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
