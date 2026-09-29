import ArgumentParser
import AVFoundation
import CoreImage
import Testing
@testable import Edith
@testable import EdithCLI

@Suite struct VideoReviewBorderTests {
    @Test func inverseCornersRejectRotatedBoundsAndRespectCropOrigin() {
        let clip = VideoProject.Clip(raw: [
            "id": "clip", "assetId": "source", "sourceStartSec": 0.0,
            "sourceEndSec": 1.0, "timelineStartSec": 0.0,
        ])
        var effects = VideoVisualEffects()
        effects.framing = .fill
        effects.keyframes = [.init(time: 0, rotation: 45)]
        let canvas = CGSize(width: 100, height: 100)
        let rotated = VideoSourceGeometry(
            extent: CGRect(x: 30, y: 50, width: 100, height: 100), clip: clip,
            effects: effects, timeMs: 0, canvas: canvas, padding: 0, zooms: [], cursor: nil)
        #expect(
            CGRect(origin: .zero, size: rotated.source.size).applying(rotated.transform).contains(
                CGRect(origin: .zero, size: canvas)))
        #expect(!rotated.covers(CGRect(origin: .zero, size: canvas)))
        effects.keyframes = []
        let plain = VideoSourceGeometry(
            extent: CGRect(x: 30, y: 50, width: 100, height: 100), clip: clip,
            effects: effects, timeMs: 0, canvas: canvas, padding: 0, zooms: [], cursor: nil)
        #expect(plain.covers(CGRect(origin: .zero, size: canvas)))
    }

    @Test func intentionalMarginsPassButAnimatedGapsFail() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await VideoReviewReportTests.fixture(directory)
        var project = try VideoProject.open(fixture.project)
        project.padding = 10
        var presentation = project.presentation
        presentation.cornerRadius = 10
        presentation.shadow = 20
        project.presentation = presentation
        try project.save(to: fixture.project)
        var options = VideoEditorService.ReviewOptions()
        options.checkBorders = true
        let report = try await VideoEditorService.reviewReport(fixture.project, options: options)
        let border = try #require(report.borders)
        #expect(report.status == .passed)
        #expect(border.coverage == "all_frames" && border.checkedFrameCount == 45)
        #expect(border.segments.allSatisfy { $0.unexpectedBorderFrames.isEmpty })
        #expect(border.segments.allSatisfy { !$0.uncoveredCanvasFrames.isEmpty })
        #expect(border.segments.allSatisfy { $0.intentionalPresentation.contains("padding") })
        #expect(
            border.segments.allSatisfy {
                $0.intentionalPresentation.contains("rounded_corners")
                    && $0.intentionalPresentation.contains("shadow")
            })
        var effects = VideoVisualEffects()
        effects.keyframes = [.init(time: 0, positionX: 0.25)]
        try project.setVisualEffects(effects, clipID: project.clips[0].id)
        try project.save(to: fixture.project)
        let shifted = try await VideoEditorService.reviewReport(fixture.project, options: options)
        #expect(shifted.status == .failed)
        #expect(shifted.borders?.segments[0].unexpectedBorderFrames == Array(0..<15))
    }

    @Test func sampledCoverageIncludesSegmentEndpointsAndTransformKeyframes() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await VideoReviewReportTests.fixture(directory)
        var project = try VideoProject.open(fixture.project)
        var effects = VideoVisualEffects()
        effects.keyframes = [.init(time: 0), .init(time: 0.2), .init(time: 0.4)]
        try project.setVisualEffects(effects, clipID: project.clips[0].id)
        try project.save(to: fixture.project)
        var options = VideoEditorService.ReviewOptions()
        options.checkBorders = true
        options.maximumBorderFrames = 15
        let report = try await VideoEditorService.reviewReport(fixture.project, options: options)
        let border = try #require(report.borders)
        #expect(report.status == .sampled && border.coverage == "sampled")
        #expect(border.checkedFrameCount <= 15 && border.mandatorySamplesComplete)
        #expect(
            Set([0, 5, 6, 7, 11, 12, 13, 14]).isSubset(of: Set(border.segments[0].checkedFrames)))
        #expect(border.segments[1].checkedFrames.contains(15))
        #expect(border.segments[1].checkedFrames.contains(44))
        options.maximumBorderFrames = 2
        let bounded = try await VideoEditorService.reviewReport(fixture.project, options: options)
        #expect(bounded.borders?.checkedFrameCount == 2)
        #expect(bounded.borders?.mandatorySamplesComplete == false)
        #expect(bounded.status != .passed)
    }

    @Test func webcamCompositingIsNeverAnAssessedPass() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await VideoReviewReportTests.fixture(directory)
        var project = try VideoProject.open(fixture.project)
        var legacy = project.root["legacyEditor"] as? [String: Any] ?? [:]
        legacy["cameraFullscreenRegions"] = [["startMs": 0.0, "endMs": 1000.0]]
        project.root["legacyEditor"] = legacy
        try project.save(to: fixture.project)
        var options = VideoEditorService.ReviewOptions()
        options.checkBorders = true
        let report = try await VideoEditorService.reviewReport(fixture.project, options: options)
        #expect(report.status == .notAssessed)
        #expect(report.borders?.segments.allSatisfy { $0.status == .notAssessed } == true)
    }

    @Test func reportRouteParsesAndRegistersWithMCP() throws {
        let parsed = try EdRoot.parseAsRoot([
            "studio", "edit", "review-report", "/synthetic.openscreen", "--expect-duration", "12",
            "--expect-frame-count", "720", "--expect-shot-count", "4", "--check-borders",
            "--max-border-frames", "100", "--output", "/review.json", "--json",
        ])
        let command = try #require(parsed as? StudioEditReviewReport)
        #expect(command.expectDuration == 12 && command.expectFrameCount == 720)
        #expect(command.expectShotCount == 4 && command.maxBorderFrames == 100)
        #expect(command.checkBorders)
        #expect(OperationMCPCatalog.tool(named: "edith_studio_edit_review_report") != nil)
        let node = try #require(CommandTree.node(at: ["studio", "edit", "review-report"]))
        #expect(node.optionValues["--output"] == .localPath)
        #expect(node.options.contains("--check-borders"))
    }

    @Test func portraitCropAndAutomaticCursorZoomUseNativeGeometry() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("portrait.mov")
        try await VideoSyntheticMovie.write(
            CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64)),
            to: movie, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0))
        let url = directory.appendingPathComponent("portrait.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Synthetic black portrait")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .videoSettings(settings: VideoSettings(width: 64, height: 64)),
                .addMedia(path: movie.path, name: "portrait"),
                .crop(clipID: "portrait", x: 0, y: 0.25, width: 1, height: 0.5),
            ]), to: url, overwrite: true)
        var options = VideoEditorService.ReviewOptions()
        options.checkBorders = true
        let cropped = try await VideoEditorService.reviewReport(url, options: options)
        #expect(cropped.status == .passed)
        #expect(cropped.borders?.segments.first?.uncoveredCanvasFrames.isEmpty == true)
        var project = try VideoProject.open(url)
        project.root["zoomRanges"] = [
            [
                "id": "zoom", "startMs": 0.0, "endMs": 1000.0, "depth": 2, "focusMode": "auto",
            ]
        ]
        try project.save(to: url)
        let samples: [[String: Any]] = (0..<10).map {
            ["timeMs": Double($0 * 100), "cx": 0.0, "cy": 0.5, "visible": true]
        }
        try JSONSerialization.data(withJSONObject: ["samples": samples]).write(
            to: URL(fileURLWithPath: movie.path + ".cursor.json"))
        let zoomed = try await VideoEditorService.reviewReport(url, options: options)
        #expect(zoomed.status == .failed)
        #expect(zoomed.borders?.segments.first?.unexpectedBorderFrames.contains(30) == true)
    }
}
