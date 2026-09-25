import CoreGraphics
import Foundation
import Testing
@testable import Edith

@Suite @MainActor struct VideoEditorModelTests {
    @Test func undoAndRedoPersistToProjectLibrary() throws {
        let model = VideoEditorModel()
        defer { model.close() }
        model.newProject()
        let url = try #require(model.project?.fileURL)
        model.setBackground("#223344")
        #expect(try VideoProject.open(url).backgroundColor == "#223344")
        model.undo()
        #expect(try VideoProject.open(url).backgroundColor == "#171b25")
        model.redo()
        #expect(try VideoProject.open(url).backgroundColor == "#223344")
    }

    @Test func zoomFrameShowsTheOutputCropAndStaysInsideTheVideo() {
        let display = CGRect(x: 20, y: 10, width: 440, height: 220)
        let source = ZoomFocusGeometry.sourceFrame(
            in: display, sourceSize: CGSize(width: 400, height: 400), padding: 10)
        #expect(abs(source.width - 176) < 0.01)
        #expect(abs(source.height - 176) < 0.01)
        #expect(source.midX == display.midX)
        #expect(source.midY == display.midY)
        let level = ZoomFocusGeometry.magnification(for: 4)
        #expect(level == 2.2)
        let centered = ZoomFocusGeometry.frame(
            in: display, magnification: level, focus: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(centered.width - 200) < 0.01)
        #expect(abs(centered.height - 100) < 0.01)
        #expect(centered.midX == display.midX)
        #expect(centered.midY == display.midY)

        let focus = ZoomFocusGeometry.focus(
            at: CGPoint(x: -100, y: 500), in: display, magnification: level)
        let edge = ZoomFocusGeometry.frame(in: display, magnification: level, focus: focus)
        #expect(edge.minX == display.minX)
        #expect(edge.maxY == display.maxY)
    }

    @Test func zoomEdgesPreviewContinuouslyAndSnapWithoutOverlappingNeighbors() {
        let range = ZoomTimelineTiming.Range(start: 2, end: 4)
        let nearPrevious = ZoomTimelineTiming.adjust(
            range, by: -0.88, edge: "start", lower: 1, upper: 6)
        #expect(nearPrevious == .init(start: 1, end: 4))
        let nearNext = ZoomTimelineTiming.adjust(
            range, by: 1.91, edge: "end", lower: 1, upper: 6)
        #expect(nearNext == .init(start: 2, end: 6))
        let moved = ZoomTimelineTiming.adjust(
            range, by: 1.9, edge: "move", lower: 1, upper: 6)
        #expect(moved == .init(start: 4, end: 6))
        #expect(
            ZoomTimelineTiming.adjust(
                range, by: -10, edge: "start", lower: 1, upper: 6
            ).start == 1)
        #expect(
            ZoomTimelineTiming.adjust(
                range, by: 10, edge: "end", lower: 1, upper: 6
            ).end == 6)
    }

    @Test func adjacentZoomLevelsBlendDirectlyAndIsolatedZoomsEaseToNormal() {
        let first = VideoProject.Zoom(raw: [
            "id": "first", "startMs": 1_000.0, "endMs": 3_000.0, "depth": 4,
            "focus": ["cx": 0.2, "cy": 0.4],
        ])
        let second = VideoProject.Zoom(raw: [
            "id": "second", "startMs": 3_000.0, "endMs": 5_000.0, "depth": 2,
            "focus": ["cx": 0.8, "cy": 0.6],
        ])
        let zooms = [first, second]
        #expect(ZoomAnimation.sample(at: 500, zooms: zooms).scale == 1)
        #expect(ZoomAnimation.sample(at: 1_300, zooms: zooms).scale == 2.2)
        let midpoint = ZoomAnimation.sample(at: 3_000, zooms: zooms)
        #expect(abs(midpoint.scale - 1.85) < 0.001)
        #expect(abs(midpoint.x - 0.5) < 0.001)
        #expect(ZoomAnimation.sample(at: 5_500, zooms: zooms).scale == 1)
        let before = ZoomAnimation.sample(at: 2_999, zooms: zooms).scale
        let after = ZoomAnimation.sample(at: 3_001, zooms: zooms).scale
        #expect(abs(before - after) < 0.02)
        var separated = second
        separated.raw["startMs"] = 3_100.0
        #expect(ZoomAnimation.sample(at: 3_050, zooms: [first, separated]).scale > 1.5)
        separated.raw["startMs"] = 3_300.0
        #expect(ZoomAnimation.sample(at: 3_150, zooms: [first, separated]).scale > 1.5)
        separated.raw["startMs"] = 4_000.0
        #expect(ZoomAnimation.sample(at: 3_500, zooms: [first, separated]).scale == 1)
    }

    @Test func exportPresetsDoNotOfferUpscaling() {
        #expect(
            VideoExportQuality.available(for: CGSize(width: 1920, height: 1080))
                == [.source, .fullHD, .hd, .sd])
        #expect(
            VideoExportQuality.available(for: CGSize(width: 640, height: 360))
                == [.source])
    }

    @Test func longZoomLengthCanReachTheNextZoomOrSourceEnd() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic.mov"), duration: 30, width: 640, height: 360)
        project.addZoom(startMs: 1_000, endMs: 3_000, depth: 4, x: 0.5, y: 0.5)
        let id = try #require(project.zooms.first?.id)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = project
        model.editingZoomID = id
        #expect(model.maximumZoomDuration == 29)
        project.updateZoom(id, duration: 14)
        #expect(project.zooms.first?.endMs == 15_000)
        project.addZoom(startMs: 20_000, endMs: 22_000, depth: 2, x: 0.5, y: 0.5)
        model.project = project
        #expect(model.maximumZoomDuration == 19)
        model.setZoomDuration(25)
        #expect(model.zoomDuration == 19)
        #expect(model.project?.zooms.first?.endMs == 20_000)
    }
}
