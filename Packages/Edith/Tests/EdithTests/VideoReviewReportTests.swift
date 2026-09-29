import AVFoundation
import CoreImage
import Testing
@testable import Edith

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
}
