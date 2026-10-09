import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Testing
@testable import StudioExtension

@Suite struct VideoReviewReportTests {
    static func fixture(_ directory: URL) async throws -> (project: URL, media: URL) {
        let media = try await VideoEditorServiceTests.movie(in: directory)
        let project = directory.appendingPathComponent("review.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic review")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .videoSettings(settings: VideoSettings(width: 64, height: 64)),
                .addMedia(path: media.path, name: "first"),
                .split(clipID: "first", sourceTime: 0.5, rightName: "second"),
                .speed(clipID: "first", rate: 2),
            ]), to: project, overwrite: true)
        return (project, media)
    }

    @Test func reportsRangesCountsMarkersAndFalseExpectationsWithoutChangingInputs() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await Self.fixture(directory)
        var project = try VideoProject.open(fixture.project)
        try project.addMarker(
            atFrame: 12, frameRate: VideoMarkerFrameRate(numerator: 60), label: "Before")
        try project.addMarker(
            atFrame: 18, frameRate: VideoMarkerFrameRate(numerator: 60), label: "After")
        try project.save(to: fixture.project)
        let before = try Data(contentsOf: fixture.project)
        let mediaBefore = try Data(contentsOf: fixture.media)
        var options = VideoEditorService.ReviewOptions()
        options.expectedDuration = 0.75
        options.expectedFrameCount = 45
        options.expectedShotCount = 2
        let report = try await VideoEditorService.reviewReport(fixture.project, options: options)
        #expect(report.status == .passed)
        #expect(report.checks.allSatisfy { $0.status == .passed })
        #expect(report.duration == 0.75 && report.frameCount == 45 && report.shotCount == 2)
        #expect(report.segments.map(\.outputFrames.start) == [0, 15])
        #expect(report.segments.map(\.outputFrames.endExclusive) == [15, 45])
        #expect(report.segments.map(\.sourceRange.start) == [0, 0.5])
        #expect(report.segments.map(\.sourceFrames?.endExclusive) == [15, 30])
        #expect(report.segments[1].nearestStartMarker?.deltaFrames == -3)
        #expect(report.clips.map(\.segmentIndices) == [[0], [1]])
        options.expectedDuration = 1
        options.expectedFrameCount = 60
        options.expectedShotCount = 3
        let failed = try await VideoEditorService.reviewReport(fixture.project, options: options)
        #expect(failed.status == .failed)
        #expect(failed.checks.allSatisfy { $0.status == .failed })
        #expect(failed.frameCount == 45)
        #expect(try Data(contentsOf: fixture.project) == before)
        #expect(try Data(contentsOf: fixture.media) == mediaBefore)
    }

    @Test func missingDependenciesProduceSerializableUnavailableMeasurements() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await Self.fixture(directory)
        try FileManager.default.removeItem(at: fixture.media)
        let before = try Data(contentsOf: fixture.project)
        var options = VideoEditorService.ReviewOptions()
        options.expectedFrameCount = 45
        let report = try await VideoEditorService.reviewReport(fixture.project, options: options)
        #expect(report.status == .failed)
        #expect(report.frameCount == nil && report.duration == nil && report.shotCount == nil)
        #expect(report.clips.count == 2 && report.segments.isEmpty)
        #expect(report.checks.first { $0.name == "frame_count" }?.status == .notAssessed)
        #expect(report.diagnostics.first?.path == fixture.media.path)
        let destination = directory.appendingPathComponent("diagnostic.json")
        _ = try VideoEditorService.writeReviewReport(
            report, project: fixture.project, to: destination)
        let decoded = try JSONDecoder().decode(
            VideoEditorService.ReviewReport.self, from: Data(contentsOf: destination))
        #expect(decoded.status == .failed)
        #expect(try Data(contentsOf: fixture.project) == before)
    }

    @Test func missingIndependentOriginalAndProcessedMusicCannotPassExpectations() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try await VideoEditorServiceTests.movie(in: directory)
        let url = directory.appendingPathComponent("music-review.openscreen")
        var project = VideoProject.create(title: "Synthetic music review")
        project.addAsset(video, duration: 1, width: 64, height: 64)
        let music = ["original.wav", "processed.wav"].map { directory.appendingPathComponent($0) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48000 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.1 }
        for source in music {
            let audio = try AVAudioFile(forWriting: source, settings: format.settings)
            try audio.write(from: buffer)
        }
        project.addAudio(music[0], duration: 1, at: 0)
        let track = try #require(project.audioTracks.first)
        var assets = project.assets.map(\.raw)
        let index = try #require(assets.firstIndex { $0["id"] as? String == track.assetID })
        assets[index]["edithAudioPath"] = music[1].path
        project.root["assets"] = assets
        try project.save(to: url)
        let before = try Data(contentsOf: url)
        var options = VideoEditorService.ReviewOptions()
        options.expectedDuration = 1
        options.expectedFrameCount = 60
        options.expectedShotCount = 1
        for source in music {
            let bytes = try Data(contentsOf: source)
            try FileManager.default.removeItem(at: source)
            let report = try await VideoEditorService.reviewReport(
                url, options: options)
            #expect(report.status == .failed)
            #expect(report.duration == nil && report.frameCount == nil && report.shotCount == nil)
            #expect(report.checks.allSatisfy { $0.status == .notAssessed })
            #expect(
                report.diagnostics.contains {
                    $0.code == "missing_or_unreadable_asset" && $0.path == source.path
                })
            #expect(try Data(contentsOf: url) == before)
            try bytes.write(to: source)
        }
        let restored = try await VideoEditorService.reviewReport(
            url, options: options)
        #expect(restored.status == .passed && restored.checks.allSatisfy { $0.status == .passed })
    }

    @Test func outputsProtectSidecarsHardlinksAndExistingReports() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await Self.fixture(directory)
        let report = try await VideoEditorService.reviewReport(fixture.project)
        let sidecar = URL(fileURLWithPath: fixture.media.path + ".session.json")
        let bytes = Data("synthetic session".utf8)
        try bytes.write(to: sidecar)
        let alias = directory.appendingPathComponent("alias.json")
        try FileManager.default.linkItem(at: fixture.media, to: alias)
        for output in [sidecar, alias] {
            #expect(throws: (any Error).self) {
                try VideoEditorService.writeReviewReport(
                    report, project: fixture.project, to: output, overwrite: true)
            }
        }
        #expect(try Data(contentsOf: sidecar) == bytes)
        let output = directory.appendingPathComponent("report.json")
        _ = try VideoEditorService.writeReviewReport(report, project: fixture.project, to: output)
        let before = try Data(contentsOf: output)
        #expect(throws: (any Error).self) {
            try VideoEditorService.writeReviewReport(report, project: fixture.project, to: output)
        }
        #expect(try Data(contentsOf: output) == before)
    }

    @Test func rationalFrameIntervalsUseExactHalfOpenBoundaries() {
        let frame = CMTime(value: 1001, timescale: 60000)
        let boundary = CMTimeMultiply(frame, multiplier: 33)
        #expect(VideoEditorService.reviewFrameCeiling(boundary, frameDuration: frame) == 33)
        #expect(
            VideoEditorService.reviewFrameCeiling(
                boundary + CMTime(value: 1, timescale: 60000), frameDuration: frame) == 34)
        #expect(
            VideoEditorService.reviewFrameCeiling(
                boundary - CMTime(value: 1, timescale: 60000), frameDuration: frame) == 33)
    }

    @Test func trimSlicesDoNotBecomeShotsAndRemovedClipsHaveNoOutputRange() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await Self.fixture(directory)
        var project = try VideoProject.open(fixture.project)
        var timeline = project.root["timeline"] as! [String: Any]
        timeline["trimRanges"] = [
            ["clipId": project.clips[0].id, "startSec": 0.1, "endSec": 0.2],
            ["clipId": project.clips[1].id, "startSec": 0.5, "endSec": 1.0],
        ]
        project.root["timeline"] = timeline
        try project.save(to: fixture.project)
        let report = try await VideoEditorService.reviewReport(fixture.project)
        #expect(report.shotCount == 1 && report.segments.count == 2)
        #expect(report.frameCount == 12)
        #expect(report.segments.map(\.outputFrames.start) == [0, 3])
        #expect(report.segments.map(\.outputFrames.endExclusive) == [3, 12])
        #expect(report.clips[1].outputRange == nil && report.clips[1].segmentIndices.isEmpty)
    }
}
