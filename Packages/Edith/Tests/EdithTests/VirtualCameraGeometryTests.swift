import CoreGraphics
import Foundation
import Testing

@testable import EdithKit

@Suite struct VirtualCameraGeometryTests {
    let hd = CGSize(width: 1920, height: 1080)
    let fourByThree = CGSize(width: 1600, height: 1200)

    @Test func baseCropFillsTheOutputAspect() {
        #expect(VirtualCameraGeometry.baseCropSize(source: hd, output: hd, tilt: 0) == hd)
        let base = VirtualCameraGeometry.baseCropSize(source: fourByThree, output: hd, tilt: 0)
        #expect(base.width == 1600)
        #expect(abs(base.height - 900) < 0.001)
        let portrait = VirtualCameraGeometry.baseCropSize(
            source: CGSize(width: 1080, height: 1920), output: hd, tilt: 0)
        #expect(portrait.width == 1080)
        #expect(abs(portrait.height - 607.5) < 0.001)
        #expect(VirtualCameraGeometry.baseCropSize(source: .zero, output: hd, tilt: 0) == .zero)
    }

    @Test func tiltShrinksTheCropSoTheRotatedFrameStaysInside() {
        let crop = VirtualCameraGeometry.crop(
            source: hd, output: hd, framing: VirtualCameraFraming(tilt: 10))
        let bounds = crop.boundingSize
        #expect(bounds.width <= hd.width + 0.001)
        #expect(bounds.height <= hd.height + 0.001)
        #expect(crop.size.width < hd.width)
        #expect(abs(crop.size.width / crop.size.height - 16.0 / 9.0) < 0.001)
    }

    @Test func zoomHalvesTheCropAroundTheCenter() {
        let crop = VirtualCameraGeometry.crop(
            source: hd, output: hd, framing: VirtualCameraFraming(zoom: 2))
        #expect(crop.size == CGSize(width: 960, height: 540))
        #expect(crop.center == CGPoint(x: 960, y: 540))
        #expect(crop.rect == CGRect(x: 480, y: 270, width: 960, height: 540))
    }

    @Test func cropCentersAreClampedInsideTheSource() {
        let corner = VirtualCameraGeometry.crop(
            source: hd, output: hd, framing: VirtualCameraFraming(zoom: 2, centerX: 0, centerY: 1))
        #expect(corner.rect.minX == 0)
        #expect(corner.rect.maxY == 1080)
        let unzoomed = VirtualCameraGeometry.crop(
            source: hd, output: hd, framing: VirtualCameraFraming(centerX: 0.9, centerY: 0.1))
        #expect(unzoomed.center == CGPoint(x: 960, y: 540))
        let clamped = VirtualCameraGeometry.clamped(
            VirtualCameraFraming(zoom: 2, centerX: 0.99), source: hd, output: hd)
        #expect(abs(clamped.centerX - 0.75) < 0.0001)
    }

    @Test func draggingMovesThePictureWithThePointer() {
        let start = VirtualCameraFraming(zoom: 2)
        let right = VirtualCameraGeometry.panned(
            start, by: CGSize(width: 100, height: 0), viewSize: CGSize(width: 960, height: 540),
            source: hd, output: hd)
        #expect(right.centerX < start.centerX)
        #expect(abs((start.centerX - right.centerX) * 1920 - 100) < 0.01)
        let down = VirtualCameraGeometry.panned(
            start, by: CGSize(width: 0, height: 50), viewSize: CGSize(width: 960, height: 540),
            source: hd, output: hd)
        #expect(down.centerY < start.centerY)
        let far = VirtualCameraGeometry.panned(
            start, by: CGSize(width: -5000, height: 0), viewSize: CGSize(width: 960, height: 540),
            source: hd, output: hd)
        #expect(abs(far.centerX - 0.75) < 0.0001)
        let untouched = VirtualCameraGeometry.panned(
            start, by: CGSize(width: 10, height: 10), viewSize: .zero, source: hd, output: hd)
        #expect(untouched == start)
    }

    @Test func draggingFollowsTheTiltedAxes() {
        let tilted = VirtualCameraFraming(zoom: 3, tilt: 30)
        let moved = VirtualCameraGeometry.panned(
            tilted, by: CGSize(width: 100, height: 0), viewSize: CGSize(width: 960, height: 540),
            source: hd, output: hd)
        #expect(moved.centerX < tilted.centerX)
        #expect(moved.centerY < tilted.centerY)
    }

    @Test func zoomKeepsTheAnchoredPointStill() {
        let start = VirtualCameraFraming(zoom: 1.5, centerX: 0.45, centerY: 0.55)
        let anchor = CGPoint(x: 0.8, y: 0.3)
        let before = VirtualCameraGeometry.crop(source: hd, output: hd, framing: start)
        let zoomed = VirtualCameraGeometry.zoomed(
            start, by: 1.5, anchor: anchor, source: hd, output: hd)
        let after = VirtualCameraGeometry.crop(source: hd, output: hd, framing: zoomed)
        let pointBefore = CGPoint(
            x: before.rect.minX + anchor.x * before.size.width,
            y: before.rect.minY + anchor.y * before.size.height)
        let pointAfter = CGPoint(
            x: after.rect.minX + anchor.x * after.size.width,
            y: after.rect.minY + anchor.y * after.size.height)
        #expect(abs(zoomed.zoom - 2.25) < 0.0001)
        #expect(abs(pointBefore.x - pointAfter.x) < 0.01)
        #expect(abs(pointBefore.y - pointAfter.y) < 0.01)
        let maxed = VirtualCameraGeometry.zoomed(
            start, by: 100, anchor: anchor, source: hd, output: hd)
        #expect(maxed.zoom == VirtualCameraFraming.zoomRange.upperBound)
        let out = VirtualCameraGeometry.zoomed(
            start, by: 0.01, anchor: anchor, source: hd, output: hd)
        #expect(out.zoom == 1)
        #expect(out.centerX == 0.5 && out.centerY == 0.5)
        #expect(
            VirtualCameraGeometry.zoomed(start, by: .nan, anchor: anchor, source: hd, output: hd)
                == start)
    }

    @Test func interpolationEasesAndZoomsGeometrically() {
        let from = VirtualCameraFraming(zoom: 1, centerX: 0.3, flipHorizontal: false)
        let to = VirtualCameraFraming(zoom: 4, centerX: 0.7, tilt: 10, flipHorizontal: true)
        #expect(VirtualCameraGeometry.interpolate(from, to, progress: 0) == from)
        #expect(VirtualCameraGeometry.interpolate(from, to, progress: 1) == to)
        let middle = VirtualCameraGeometry.interpolate(from, to, progress: 0.5)
        #expect(abs(middle.zoom - 2) < 0.0001)
        #expect(abs(middle.centerX - 0.5) < 0.0001)
        #expect(abs(middle.tilt - 5) < 0.0001)
        #expect(middle.flipHorizontal)
        let early = VirtualCameraGeometry.interpolate(from, to, progress: 0.1)
        #expect(early.centerX - 0.3 < 0.04 * 0.4)
        #expect(!early.flipHorizontal)
    }

    @Test func sharpZoomAsksForEnoughSourcePixels() {
        #expect(
            VirtualCameraGeometry.requiredSourceWidth(output: hd, zoom: 1, sourceAspect: 16 / 9)
                == 1920)
        #expect(
            VirtualCameraGeometry.requiredSourceWidth(output: hd, zoom: 2, sourceAspect: 16 / 9)
                == 3840)
        #expect(
            VirtualCameraGeometry.requiredSourceWidth(
                output: CGSize(width: 1280, height: 720), zoom: 1.5, sourceAspect: 4 / 3) == 1920)
        #expect(
            VirtualCameraGeometry.requiredSourceWidth(output: .zero, zoom: 2, sourceAspect: 1) == 0)
    }

    @Test func quarterTurnsSwapTheOrientedSize() {
        #expect(
            VirtualCameraGeometry.orientedSize(hd, quarterTurns: 1)
                == CGSize(width: 1080, height: 1920))
        #expect(VirtualCameraGeometry.orientedSize(hd, quarterTurns: 2) == hd)
    }
}

@Suite struct VirtualCameraAutoFramerTests {
    let hd = CGSize(width: 1920, height: 1080)
    let face = CGRect(x: 0.45, y: 0.3, width: 0.1, height: 0.18)

    @Test func shotCentersTheFaceWithHeadroom() throws {
        let shot = try #require(
            VirtualCameraAutoFramer.shot(
                for: [face], mode: .medium, manual: VirtualCameraFraming(), source: hd, output: hd))
        #expect(abs(shot.zoom - 1.333) < 0.01)
        #expect(abs(shot.centerX - 0.5) < 0.0001)
        #expect(shot.centerY > face.midY)
        #expect(
            VirtualCameraAutoFramer.shot(
                for: [], mode: .medium, manual: VirtualCameraFraming(), source: hd, output: hd)
                == nil)
        #expect(
            VirtualCameraAutoFramer.shot(
                for: [face], mode: .off, manual: VirtualCameraFraming(), source: hd, output: hd)
                == nil)
    }

    @Test func tighterModesZoomFurtherButStayWithinLimits() throws {
        let manual = VirtualCameraFraming()
        let wide = try #require(
            VirtualCameraAutoFramer.shot(
                for: [face], mode: .wide, manual: manual, source: hd, output: hd))
        let close = try #require(
            VirtualCameraAutoFramer.shot(
                for: [face], mode: .close, manual: manual, source: hd, output: hd))
        #expect(close.zoom > wide.zoom)
        let tiny = CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)
        let limited = try #require(
            VirtualCameraAutoFramer.shot(
                for: [tiny], mode: .close, manual: manual, source: hd, output: hd))
        #expect(limited.zoom == VirtualCameraAutoFramer.maximumZoom)
    }

    @Test func groupsAreFramedTogether() throws {
        let left = CGRect(x: 0.1, y: 0.3, width: 0.1, height: 0.15)
        let right = CGRect(x: 0.8, y: 0.3, width: 0.1, height: 0.15)
        let shot = try #require(
            VirtualCameraAutoFramer.shot(
                for: [left, right], mode: .close, manual: VirtualCameraFraming(), source: hd,
                output: hd))
        #expect(abs(shot.centerX - 0.5) < 0.0001)
    }

    @Test func trackingEasesTowardTheFace() {
        var framer = VirtualCameraAutoFramer(timeConstant: 0.5, holdAfterLoss: 10)
        let manual = VirtualCameraFraming()
        let first = framer.update(
            faces: [face], mode: .medium, manual: manual, source: hd, output: hd, at: 0)
        let target = framer.goal
        #expect(first.centerX == target?.centerX)
        let movedFace = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.18)
        let step = framer.update(
            faces: [movedFace], mode: .medium, manual: manual, source: hd, output: hd, at: 0.1)
        let goal = framer.goal?.centerX ?? 0
        #expect(step.centerX < first.centerX)
        #expect(step.centerX > goal)
        var settled = step
        for tick in 1...80 {
            settled = framer.update(
                faces: nil, mode: .medium, manual: manual, source: hd, output: hd,
                at: 0.1 + Double(tick) * 0.02)
        }
        #expect(abs(settled.centerX - goal) < 0.01)
    }

    @Test func smallJitterStaysInsideTheDeadZone() {
        var framer = VirtualCameraAutoFramer()
        let manual = VirtualCameraFraming()
        _ = framer.update(
            faces: [face], mode: .medium, manual: manual, source: hd, output: hd, at: 0)
        let goal = framer.goal
        let jittered = face.offsetBy(dx: 0.003, dy: -0.002)
        _ = framer.update(
            faces: [jittered], mode: .medium, manual: manual, source: hd, output: hd, at: 0.05)
        #expect(framer.goal == goal)
    }

    @Test func lostFacesReturnToTheManualFraming() {
        var framer = VirtualCameraAutoFramer(timeConstant: 0.01, holdAfterLoss: 1)
        let manual = VirtualCameraFraming(zoom: 1.2, centerX: 0.5, centerY: 0.5)
        _ = framer.update(
            faces: [face], mode: .close, manual: manual, source: hd, output: hd, at: 0)
        let held = framer.update(
            faces: [], mode: .close, manual: manual, source: hd, output: hd, at: 0.5)
        #expect(held.zoom > 1.2)
        _ = framer.update(faces: [], mode: .close, manual: manual, source: hd, output: hd, at: 2)
        let back = framer.update(
            faces: nil, mode: .close, manual: manual, source: hd, output: hd, at: 3)
        #expect(abs(back.zoom - 1.2) < 0.001)
        #expect(abs(back.centerX - 0.5) < 0.001)
    }

    @Test func turningTrackingOffResetsIt() {
        var framer = VirtualCameraAutoFramer()
        let manual = VirtualCameraFraming(zoom: 1.1)
        _ = framer.update(faces: [face], mode: .wide, manual: manual, source: hd, output: hd, at: 0)
        #expect(framer.current != nil)
        let off = framer.update(
            faces: [face], mode: .off, manual: manual, source: hd, output: hd, at: 1)
        #expect(off == manual)
        #expect(framer.current == nil && framer.goal == nil)
    }
}
