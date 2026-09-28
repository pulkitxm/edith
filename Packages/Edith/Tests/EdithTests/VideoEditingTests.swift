import CoreGraphics
import Foundation
import Testing
@testable import Edith

@Suite struct VideoEditingTests {
    @Test func movingAnOverlayReanchorsItToItsNewClip() throws {
        var project = fixture()
        project.addText("Callout", startMs: 1000, endMs: 3000)
        let id = try #require(project.annotations.first?.id)
        project.retimeRegion("annotations", id: id, start: 6, end: 8, trimStart: false)
        let moved = try #require(project.annotations.first)
        #expect(moved.raw["clipId"] as? String == project.clips[1].id)
        project.setClips(project.clips.reversed())
        #expect(project.annotations.first?.startMs == 1000)
        #expect(project.annotations.first?.endMs == 3000)
    }

    @Test func trimmingAudioAdvancesSourceOffsetButMovingDoesNot() throws {
        var project = fixture()
        project.addAudio(URL(fileURLWithPath: "/synthetic/music.m4a"), duration: 5, at: 0)
        let id = try #require(project.audioTracks.first?.id)
        project.retimeRegion("audioTracks", id: id, start: 1, end: 4, trimStart: true)
        #expect(project.audioTracks.first?.offsetMs == 1000)
        project.retimeRegion("audioTracks", id: id, start: 2, end: 5, trimStart: false)
        #expect(project.audioTracks.first?.offsetMs == 1000)
    }

    @Test func canvasSnapsAndClampsWithoutInvertingTheRegion() {
        let original = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2)
        let centered = VideoCanvasGeometry.adjust(
            original,
            translation: CGSize(width: 0.149, height: 0.199), handle: "move")
        #expect(abs(centered.midX - 0.5) < 0.001)
        #expect(abs(centered.midY - 0.5) < 0.001)
        let clamped = VideoCanvasGeometry.adjust(
            original,
            translation: CGSize(width: 9, height: -9), handle: "move")
        #expect(clamped.maxX == 1)
        #expect(clamped.minY == 0)
        let small = VideoCanvasGeometry.adjust(
            original,
            translation: CGSize(width: -9, height: -9), handle: "resize")
        #expect(small.width == 0.03)
        #expect(small.height == 0.03)
    }

    private func fixture() -> VideoProject {
        var project = VideoProject.create()
        for index in 0..<2 {
            project.addAsset(
                URL(fileURLWithPath: "/synthetic/clip-\(index).mp4"),
                duration: 5, width: 1280, height: 720)
        }
        return project
    }
}
