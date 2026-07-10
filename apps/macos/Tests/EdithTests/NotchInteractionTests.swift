import CoreGraphics
import Foundation
import Testing

@testable import EdithMenuBar

@Suite struct NotchHoverGateTests {
    @Test func opensOnlyAfterDwellInsideOpenZone() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        let scheduled = gate.sample(.open, now: 0)
        #expect(scheduled == .schedule(deadline: 0.1))
        #expect(gate.isOpen == false)

        #expect(gate.fire(now: 0.05) == .none)
        #expect(gate.isOpen == false)

        #expect(gate.fire(now: 0.1) == .opened)
        #expect(gate.isOpen)
    }

    @Test func brushingThroughOpenZoneNeverOpens() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.sample(.open, now: 0) == .schedule(deadline: 0.1))
        let cancelled = gate.sample(.outside, now: 0.05)
        #expect(cancelled == .cancelPending)
        #expect(gate.fire(now: 0.2) == .none)
        #expect(gate.isOpen == false)
    }

    @Test func keepOpenZoneDoesNotTriggerOpening() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.sample(.keepOpen, now: 0) == .none)
        #expect(gate.hasPending == false)
        #expect(gate.isOpen == false)
    }

    @Test func staysOpenWhileInKeepOpenZone() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        #expect(gate.sample(.keepOpen, now: 1.0) == .none)
        #expect(gate.hasPending == false)
        #expect(gate.isOpen)
    }

    @Test func closesOnlyAfterGraceOutsideKeepOpenZone() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        #expect(gate.sample(.outside, now: 1.0) == .schedule(deadline: 1.4))
        #expect(gate.fire(now: 1.2) == .none)
        #expect(gate.isOpen)
        #expect(gate.fire(now: 1.4) == .closed)
        #expect(gate.isOpen == false)
    }

    @Test func returningToKeepOpenCancelsPendingClose() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        #expect(gate.sample(.outside, now: 1.0) == .schedule(deadline: 1.4))
        #expect(gate.sample(.keepOpen, now: 1.2) == .cancelPending)
        #expect(gate.fire(now: 2.0) == .none)
        #expect(gate.isOpen)
    }

    @Test func openAndCloseUseDifferentBoundaries() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.sample(.keepOpen, now: 0) == .none)
        #expect(gate.isOpen == false)
        gate.forceOpen()
        #expect(gate.sample(.keepOpen, now: 1.0) == .none)
        #expect(gate.isOpen)
    }

    @Test func repeatedSamplesDoNotRescheduleSameTarget() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.sample(.open, now: 0) == .schedule(deadline: 0.1))
        #expect(gate.sample(.open, now: 0.02) == .none)
        #expect(gate.sample(.open, now: 0.05) == .none)
        #expect(gate.fire(now: 0.1) == .opened)
    }

    @Test func fireBeforeAnySampleIsNoop() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.fire(now: 5) == .none)
        #expect(gate.isOpen == false)
    }

    @Test func forceClosedClearsPending() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        _ = gate.sample(.outside, now: 0)
        #expect(gate.hasPending)
        gate.forceClosed()
        #expect(gate.isOpen == false)
        #expect(gate.hasPending == false)
    }

    @Test func negativeDurationsAreClampedToZero() {
        var gate = NotchHoverGate(openDwell: -1, closeGrace: -1)
        #expect(gate.openDwell == 0)
        #expect(gate.closeGrace == 0)
        #expect(gate.sample(.open, now: 3) == .schedule(deadline: 3))
        #expect(gate.fire(now: 3) == .opened)
    }
}

@Suite struct NotchProximityGeometryTests {
    private let collapsed = CGRect(x: 676, y: 950, width: 160, height: 32)
    private let expanded = CGRect(x: 576, y: 792, width: 360, height: 190)

    @Test func pointInsideCollapsedIsOpen() {
        let p = NotchGeometry.proximity(
            point: CGPoint(x: 756, y: 965), collapsedFrame: collapsed, expandedFrame: expanded)
        #expect(p == .open)
    }

    @Test func withinOpenMarginStillCountsAsOpen() {
        let justAbove = CGPoint(x: 756, y: collapsed.maxY + NotchGeometry.openMargin - 1)
        #expect(
            NotchGeometry.proximity(
                point: justAbove, collapsedFrame: collapsed, expandedFrame: expanded) == .open)
    }

    @Test func insideExpandedButOutsideCollapsedIsKeepOpen() {
        let p = NotchGeometry.proximity(
            point: CGPoint(x: 600, y: 820), collapsedFrame: collapsed, expandedFrame: expanded)
        #expect(p == .keepOpen)
    }

    @Test func farAwayIsOutside() {
        let p = NotchGeometry.proximity(
            point: CGPoint(x: 100, y: 100), collapsedFrame: collapsed, expandedFrame: expanded)
        #expect(p == .outside)
    }

    @Test func keepOpenMarginExtendsBeyondExpandedFrame() {
        let justBelow = CGPoint(x: 756, y: expanded.minY - NotchGeometry.keepOpenMargin + 1)
        #expect(
            NotchGeometry.proximity(
                point: justBelow, collapsedFrame: collapsed, expandedFrame: expanded) == .keepOpen)
    }

    @Test func openZoneImpliesKeepOpenZone() {
        let center = CGPoint(x: collapsed.midX, y: collapsed.midY)
        let onlyKeep = NotchGeometry.proximity(
            point: center, collapsedFrame: collapsed, expandedFrame: .zero,
            openMargin: -1000, keepOpenMargin: NotchGeometry.keepOpenMargin)
        #expect(onlyKeep == .outside)
        let asOpen = NotchGeometry.proximity(
            point: center, collapsedFrame: collapsed, expandedFrame: expanded)
        #expect(asOpen == .open)
    }
}

@Suite struct NotchInteractionScenarioTests {
    private let collapsed = CGRect(x: 676, y: 950, width: 160, height: 32)
    private let expanded = CGRect(x: 576, y: 792, width: 360, height: 190)

    private func proximity(_ point: CGPoint) -> NotchProximity {
        NotchGeometry.proximity(point: point, collapsedFrame: collapsed, expandedFrame: expanded)
    }

    private func drive(_ gate: inout NotchHoverGate, point: CGPoint, at now: TimeInterval) {
        if case .schedule(let deadline) = gate.sample(proximity(point), now: now) {
            if now >= deadline { _ = gate.fire(now: now) }
        }
        _ = gate.fire(now: now)
    }

    @Test func approachDwellOpenLingerLeaveGraceClose() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        let onNotch = CGPoint(x: 756, y: 965)
        let insideShelf = CGPoint(x: 700, y: 830)
        let away = CGPoint(x: 200, y: 400)

        drive(&gate, point: onNotch, at: 0.0)
        #expect(gate.isOpen == false)
        drive(&gate, point: onNotch, at: 0.12)
        #expect(gate.isOpen)

        drive(&gate, point: insideShelf, at: 0.5)
        #expect(gate.isOpen)
        drive(&gate, point: insideShelf, at: 1.0)
        #expect(gate.isOpen)

        drive(&gate, point: away, at: 2.0)
        #expect(gate.isOpen)
        drive(&gate, point: away, at: 2.45)
        #expect(gate.isOpen == false)
    }

    @Test func oscillatingAtBoundaryDoesNotFlicker() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        let justInside = CGPoint(x: 756, y: expanded.minY - NotchGeometry.keepOpenMargin + 2)
        let justOutside = CGPoint(x: 756, y: expanded.minY - NotchGeometry.keepOpenMargin - 2)
        var now = 1.0
        for _ in 0..<20 {
            drive(&gate, point: justOutside, at: now)
            now += 0.05
            drive(&gate, point: justInside, at: now)
            now += 0.05
        }
        #expect(gate.isOpen)
    }

    @Test func quickSwipePastNotchNeverOpens() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        drive(&gate, point: CGPoint(x: 756, y: 965), at: 0.0)
        drive(&gate, point: CGPoint(x: 900, y: 965), at: 0.04)
        drive(&gate, point: CGPoint(x: 1100, y: 965), at: 0.08)
        #expect(gate.isOpen == false)
        #expect(gate.hasPending == false)
    }
}

@Suite struct HardwareNotchRectTests {
    @Test func rectIsCenteredAtTopOfPanel() {
        let rect = NotchGeometry.hardwareNotchRect(
            in: CGSize(width: 360, height: 190), collapsedSize: CGSize(width: 160, height: 32))
        #expect(rect.width == 160)
        #expect(rect.height == 32)
        #expect(rect.minX == 100)
        #expect(rect.maxY == 190)
        #expect(rect.minY == 158)
    }

    @Test func rectNeverExceedsPanelBounds() {
        let rect = NotchGeometry.hardwareNotchRect(
            in: CGSize(width: 120, height: 20), collapsedSize: CGSize(width: 160, height: 32))
        #expect(rect.width == 120)
        #expect(rect.height == 20)
        #expect(rect.minX == 0)
    }
}
