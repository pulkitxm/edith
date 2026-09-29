import AVFoundation
import Foundation
import Testing
@testable import Edith

@Suite struct VideoMarkerServiceTests {
    static let fps = VideoEditorService.MarkerRate.explicit(.fps30)

    static func fixture(in directory: URL) async throws -> (URL, String) {
        let audio = directory.appendingPathComponent("clicks.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
        buffer.frameLength = 24000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<24000 { samples[index] = index % 4000 == 2000 ? 0.8 : 0 }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        var project = VideoProject.create(title: "Synthetic rhythm")
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        project.addAudio(audio, duration: 3, at: 0)
        let url = directory.appendingPathComponent("rhythm.openscreen")
        try project.save(to: url)
        return (url, try #require(project.audioTracks.first?.id))
    }

    @Test func mutationRoundTripDryRunAndSnapAreTyped() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("markers.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Synthetic markers")
        let original = try Data(contentsOf: url)
        let change = VideoEditorService.MarkerChange.add(frame: 30, rate: Self.fps, label: "Cue")
        #expect(try await !VideoEditorService.changeMarkers(change, in: url, dryRun: true).written)
        #expect(try Data(contentsOf: url) == original)
        let added = try await VideoEditorService.changeMarkers(change, in: url)
        let marker = try #require(added.markers.first)
        #expect(added.positionUnit == "output_frames")
        _ = try await VideoEditorService.changeMarkers(
            .update(id: marker.id, frame: 60, rate: Self.fps, label: "Moved"), in: url)
        let snap = try await VideoEditorService.snapMarker(
            url, frame: 62, thresholdFrames: 2, rate: Self.fps)
        #expect(snap.matched && snap.outputFrame == 60 && snap.outputSeconds == 2)
        #expect(snap.nonDropFrameTimecode == "00:00:02:00")
        let output = directory.appendingPathComponent("markers.json")
        _ = try VideoEditorService.exportMarkers(url, to: output)
        let data = try Data(contentsOf: output)
        _ = try await VideoEditorService.changeMarkers(.remove(id: marker.id), in: url)
        #expect(try VideoEditorService.listMarkers(url).markers.isEmpty)
        _ = try await VideoEditorService.changeMarkers(
            .importDocument(data, replace: false), in: url)
        let before = try Data(contentsOf: url)
        for invalid in [
            VideoEditorService.MarkerChange.importDocument(data, replace: false),
            .add(frame: -1, rate: Self.fps, label: "Invalid"),
            .update(id: marker.id, frame: 2, rate: nil, label: nil),
        ] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.changeMarkers(invalid, in: url)
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func concurrentTransactionsPreserveBothMarkersAndRejectStaleNativeSaves() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Concurrent markers")
        var stale = try VideoProject.open(url)
        async let first = VideoEditorService.changeMarkers(
            .add(frame: 1, rate: Self.fps, label: "First"), in: url)
        async let second = VideoEditorService.changeMarkers(
            .add(frame: 2, rate: Self.fps, label: "Second"), in: url)
        _ = try await (first, second)
        #expect(
            Set(try VideoEditorService.listMarkers(url).markers.map(\.label)) == [
                "First", "Second",
            ])
        let before = try Data(contentsOf: url)
        stale.rename("Stale")
        #expect(throws: (any Error).self) { try stale.save(to: url) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func projectFPSUsesSavedRationalAndNeverDefaultsForEmptyProjects() async throws {
        var project = VideoProject.create()
        #expect(
            try await VideoEditorService.markerFrameRate(.project, project: project).framesPerSecond
                == 60)
        project.root.removeValue(forKey: "edithVideoSettings")
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.markerFrameRate(.project, project: project)
        }
        for (numerator, denominator) in [(2_000_000, 100_000), (60000, 1001)] {
            project.root["edithVideoSettings"] = [
                "frameRateNumerator": numerator, "frameRateDenominator": denominator,
            ]
            #expect(
                try await VideoEditorService.markerFrameRate(.project, project: project)
                    == VideoMarkerFrameRate(numerator: numerator, denominator: denominator))
        }
        project.root["edithVideoSettings"] = ["frameRateNumerator": 60, "frameRateDenominator": 0]
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.markerFrameRate(.project, project: project)
        }
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        project = .create()
        project.root.removeValue(forKey: "edithVideoSettings")
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        #expect(
            try await VideoEditorService.markerFrameRate(.project, project: project).framesPerSecond
                == 60)
    }

    @Test func independentMusicAnalysisUsesRawSourceTimeAndProcessedPrecedence() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, id) = try await Self.fixture(in: directory)
        var project = try VideoProject.open(url)
        let track = try #require(project.audioTracks.first(where: { $0.id == id }))
        #expect(!project.clips.contains { $0.assetID == track.assetID })
        #expect(track.endMs == 1000)
        project.editRegion("audioTracks", id: id) {
            $0["offsetMs"] = 500
            $0["rate"] = 2
            $0["loop"] = true
            $0["muted"] = true
        }
        try project.save(to: url)
        let before = try Data(contentsOf: url)
        let mapping = VideoEditorService.AudioMarkerMapping(
            sourceInSeconds: 1, sourceOutSeconds: 3, outputStartSeconds: 10, playbackRate: 2)
        let report = try await VideoEditorService.analyzeAudio(
            url, assetID: id, mapping: mapping, rate: Self.fps)
        #expect(report.assetID == id)
        #expect(report.durationSeconds == 3)
        #expect(report.analysis.sampleCount == 24000)
        #expect(report.analysis.transients.count == 6)
        #expect(report.markerDocument?.markers.map(\.frame) == [304, 311, 319, 326])
        #expect(try Data(contentsOf: url) == before)
        let sourceReport = try await VideoEditorService.analyzeAudio(url, assetID: track.assetID)
        #expect(sourceReport.analysis == report.analysis)
        let processed = directory.appendingPathComponent("processed.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<8000 { samples[index] = 0 }
        try AVAudioFile(forWriting: processed, settings: format.settings).write(from: buffer)
        var assets = project.assets.map(\.raw)
        let index = try #require(assets.firstIndex { $0["id"] as? String == track.assetID })
        assets[index]["edithAudioPath"] = processed.path
        project.root["assets"] = assets
        try project.save(to: url)
        let processedReport = try await VideoEditorService.analyzeAudio(url, assetID: id)
        #expect(processedReport.sourcePath == processed.path)
        #expect(processedReport.durationSeconds == 1)
        #expect(processedReport.analysis.transients.isEmpty)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.analyzeAudio(
                url, assetID: id, mapping: mapping, rate: Self.fps)
        }
        var options = VideoEditorService.AudioAnalysisOptions()
        options.maximumWaveformBins = 3
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.analyzeAudio(url, assetID: id, options: options)
        }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.analyzeAudio(url, assetID: "missing-track")
        }
        project.editRegion("audioTracks", id: id) { $0["assetId"] = "missing-source" }
        try project.save(to: url)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.analyzeAudio(url, assetID: id)
        }
    }

    @Test func visualAssetAnalysisMapsSourceSecondsAndUsesProcessedAudio() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, _) = try await Self.fixture(in: directory)
        var project = try VideoProject.open(url)
        let id = try #require(
            project.assets.first(where: { $0.raw["kind"] as? String == "video" })?.id)
        var assets = project.assets.map(\.raw)
        let index = try #require(assets.firstIndex(where: { $0["id"] as? String == id }))
        assets[index]["edithAudioPath"] = directory.appendingPathComponent("clicks.caf").path
        project.root["assets"] = assets
        try project.save(to: url)
        let before = try Data(contentsOf: url)
        let report = try await VideoEditorService.analyzeAudio(
            url, assetID: id,
            mapping: .init(
                sourceInSeconds: 1, sourceOutSeconds: 3, outputStartSeconds: 10, playbackRate: 2),
            rate: Self.fps)
        #expect(report.analysis.transients.count == 6)
        #expect(report.durationSeconds == 3)
        #expect(report.sourcePath == directory.appendingPathComponent("clicks.caf").path)
        #expect(report.markerDocument?.markers.map(\.frame) == [304, 311, 319, 326])
        #expect(report.samplePositionUnit == "source_samples" && report.sampleRateUnit == "Hz")
        #expect(try JSONEncoder().encode(report).count < 4 << 20)
        #expect(try Data(contentsOf: url) == before)
        assets[index]["kind"] = "image"
        project.root["assets"] = assets
        try project.save(to: url)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.analyzeAudio(url, assetID: id)
        }
    }

    @Test func corruptMarkersAndProtectedExportsPreserveBytes() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, _) = try await Self.fixture(in: directory)
        let sentinel = Data("synthetic cursor telemetry".utf8)
        for suffix in [".cursor.json", ".session.json"] {
            let sidecar = directory.appendingPathComponent("clicks.caf" + suffix)
            try sentinel.write(to: sidecar)
            #expect(throws: (any Error).self) {
                try VideoEditorService.exportMarkers(url, to: sidecar, overwrite: true)
            }
            #expect(try Data(contentsOf: sidecar) == sentinel)
        }
        var project = try VideoProject.open(url)
        project.root["edithMarkers"] = [["frame": -1]]
        try project.save(to: url)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try VideoEditorService.listMarkers(url) }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.changeMarkers(
                .add(frame: 1, rate: Self.fps, label: "Cue"), in: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func oversizedMutationReportIsRejectedBeforePublishing() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bounded.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Bounded output")
        let before = try Data(contentsOf: url)
        let markers = try (0..<1200).map {
            try VideoMarker(
                id: "cue-\($0)", frame: Int64($0), label: String(repeating: "a", count: 3800))
        }
        let document = try VideoMarkers.export(markers)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.changeMarkers(
                .importDocument(document, replace: true), in: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
