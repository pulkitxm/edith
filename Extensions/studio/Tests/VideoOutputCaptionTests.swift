import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import StudioExtension

@Suite struct VideoOutputCaptionTests {
    static func fixture() async throws -> (URL, URL, VideoProject) {
        let directory = try VideoEditorServiceTests.folder()
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        var project = VideoProject.create(title: "Synthetic caption timing")
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        let url = directory.appendingPathComponent("captions.openscreen")
        try project.save(to: url)
        return (directory, url, project)
    }

    @Test func exactRationalBoundsAndInvalidAnchorFields() throws {
        let rate = try VideoCaptionFrameRate(numerator: 60000, denominator: 2002)
        #expect(rate.numerator == 30000 && rate.denominator == 1001)
        let start = try VideoCaptionPosition(frame: 10, frameRate: rate)
        let end = try VideoCaptionPosition(frame: 11, frameRate: rate)
        let anchor = try VideoCaptionAnchor(start: start, end: end)
        #expect(anchor.contains(CMTime(value: 10010, timescale: 30000)))
        #expect(!anchor.contains(CMTime(value: 11011, timescale: 30000)))
        #expect(!anchor.contains(CMTime(value: 10009, timescale: 30000)))
        #expect(throws: (any Error).self) { try VideoCaptionAnchor(start: end, end: start) }
        #expect(throws: (any Error).self) { try VideoCaptionPosition(frame: -1, frameRate: rate) }
        let hugeRate = try VideoCaptionFrameRate(
            numerator: Int(Int32.max), denominator: Int(Int32.max) - 1)
        #expect(throws: (any Error).self) {
            try VideoCaptionPosition(frame: VideoMarker.maximumFrame, frameRate: hugeRate)
        }
        var raw: [String: Any] = [:]
        try anchor.store(in: &raw)
        var stored = try #require(raw["edithOutputCaption"] as? [String: Any])
        stored["typo"] = 1
        #expect(throws: (any Error).self) { try VideoCaptionAnchor.decode(stored) }
    }

    @Test func serviceSnapshotsMarkersAndKeepsStableIDsAndFailedMutationBytes() async throws {
        let (directory, url, initial) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = initial
        let rate = try VideoMarkerFrameRate(numerator: 30000, denominator: 1001)
        let start = try project.addMarker(atFrame: 6, frameRate: rate)
        let end = try project.addMarker(atFrame: 18, frameRate: rate)
        try project.save(to: url)
        let created = try await VideoEditorService.changeCaption(
            .add(
                content: "On the beat", start: .marker(start.id), end: .marker(end.id),
                rate: .project), in: url)
        let id = try #require(created.captionID)
        let originalAnchor = try #require(created.captions.first?.anchor)
        #expect(
            originalAnchor.start.frame == 6 && originalAnchor.start.frameRate.numerator == 30000)
        #expect(originalAnchor.start.markerID == start.id)
        project = try VideoProject.open(url)
        try project.updateMarker(start.id, frame: 15)
        var settings = project.videoSettings
        settings.frameRateNumerator = 24
        settings.frameRateDenominator = 1
        project.videoSettings = settings
        project.setClips(project.clips.reversed())
        try project.save(to: url)
        let updated = try await VideoEditorService.changeCaption(
            .update(id: id, content: "Still on the beat", start: nil, end: nil, rate: nil), in: url)
        #expect(updated.captionID == id && updated.captions.first?.anchor == originalAnchor)
        let before = try Data(contentsOf: url)
        let fps = try VideoCaptionFrameRate(numerator: 60)
        let invalid: [VideoEditorService.CaptionChange] = [
            .remove(id: "missing"),
            .update(id: id, content: nil, start: nil, end: nil, rate: nil),
            .update(id: id, content: "", start: nil, end: nil, rate: nil),
            .update(
                id: id, content: nil, start: .frame(100), end: .frame(110), rate: .explicit(fps)),
            .update(id: id, content: nil, start: .frame(40), end: .frame(20), rate: .explicit(fps)),
            .update(id: id, content: nil, start: .frame(1), end: nil, rate: nil),
            .update(id: id, content: nil, start: .marker("missing"), end: nil, rate: nil),
            .add(
                content: String(repeating: "x", count: 10001), start: .frame(1), end: .frame(2),
                rate: .explicit(fps)),
        ]
        for change in invalid {
            do {
                _ = try await VideoEditorService.changeCaption(change, in: url);
                Issue.record("Mutation succeeded")
            } catch {}
            #expect(try Data(contentsOf: url) == before)
        }
        let preview = try await VideoEditorService.changeCaption(
            .remove(id: id), in: url, dryRun: true)
        #expect(!preview.written && preview.captions.isEmpty)
        #expect(try Data(contentsOf: url) == before)
        let removed = try await VideoEditorService.changeCaption(.remove(id: id), in: url)
        #expect(removed.captionID == id && removed.captions.isEmpty)
    }

    @Test func nativeFramesAndExportsKeepOutputTimingAcrossSpeedSkipsAndReorder() async throws {
        let (directory, url, _) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rate = try VideoCaptionFrameRate(numerator: 60)
        let report = try await VideoEditorService.changeCaption(
            .add(content: "BEAT", start: .frame(12), end: .frame(24), rate: .explicit(rate)),
            in: url)
        let id = try #require(report.captionID)
        var project = try VideoProject.open(url)
        project.setAnnotationStyle(id, key: "backgroundColor", value: "#00ff00")
        project.editRegion("annotations", id: id) { $0["size"] = ["width": 80, "height": 50] }
        let original = try #require(project.annotations.first?.outputCaption)
        for variant in 0..<3 {
            if variant == 1 { project.addTrim(clipID: project.clips[0].id, start: 0.2, end: 0.4) }
            if variant == 2 { project.setClips(project.clips.reversed()) }
            #expect(project.annotations.first?.outputCaption == original)
            let pipeline = try await VideoRenderPipeline.make(project: project)
            let native = AVAssetImageGenerator(asset: pipeline.composition)
            native.videoComposition = pipeline.videoComposition
            let output = directory.appendingPathComponent("caption-\(variant).mp4")
            try await pipeline.exportMP4(to: output)
            let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            for generator in [native, exported] {
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                for frame: Int64 in [11, 12, 23, 24, 36] {
                    let image = try await generator.image(at: CMTime(value: frame, timescale: 60))
                        .image
                    #expect(
                        (Self.greenPixels(image) > 50) == (frame >= 12 && frame < 24),
                        "variant \(variant), frame \(frame)")
                }
            }
        }
    }

    static func greenPixels(_ image: CGImage) -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        CIContext().render(
            CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0 + 1] > 150 && bytes[$0] < 100
        }.count
    }

    @Test @MainActor func nativeRetimeSplitMergeAndUndoPreserveTheOutputClock() async throws {
        let (directory, url, _) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await VideoEditorService.changeCaption(
            .add(content: "First second", start: .frame(12), end: .frame(48), rate: .project),
            in: url)
        let id = try #require(report.captionID)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = try VideoProject.open(url)
        model.retime("annotations", id: id, range: .init(start: 0.3, end: 0.9), edge: "move")
        #expect(model.project?.annotations.first?.outputCaption?.start.frame == 18)
        model.undo()
        #expect(model.project?.annotations.first?.outputCaption?.start.frame == 12)
        model.redo()
        model.mutate { $0.splitCaption(id, at: 600) }
        #expect(model.project?.annotations.count == 2)
        #expect(
            model.project?.annotations.allSatisfy {
                $0.outputCaption != nil && $0.raw["clipId"] == nil
            } == true)
        model.mutate { $0.mergeCaption(id) }
        let caption = try #require(model.project?.annotations.first)
        #expect(model.project?.annotations.count == 1)
        #expect(caption.outputCaption?.start.frame == 18 && caption.outputCaption?.end.frame == 54)
        #expect(model.captionOutputRange(caption).start == 0.3)
        #expect(
            try VideoProject.open(url).annotations.first?.outputCaption == caption.outputCaption)
    }
}
