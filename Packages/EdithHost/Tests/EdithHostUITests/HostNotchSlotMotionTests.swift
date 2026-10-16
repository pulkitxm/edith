import AppKit
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchSlotMotionTests {
    private func container() -> HostNotchContainerController {
        let container = HostNotchContainerController()
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        return container
    }

    private func slot() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }

    @Test func firstPlacementDoesNotAnimate() {
        let container = container()
        let slot = slot()
        container.attach(slot, rectangle: CGRect(x: 10, y: 0, width: 100, height: 30), native: true)
        #expect(!container.slotAnimating)
    }

    @Test func movedSlotGlidesToItsNewFrame() {
        let container = container()
        let slot = slot()
        container.attach(slot, rectangle: CGRect(x: 10, y: 0, width: 100, height: 30), native: true)
        container.attach(slot, rectangle: CGRect(x: 40, y: 0, width: 160, height: 30), native: true)
        #expect(container.slotAnimating)
        #expect(slot.view.frame == CGRect(x: 40, y: 0, width: 160, height: 30))
    }

    @Test func unchangedFrameDoesNotRestartTheGlide() {
        let container = container()
        let slot = slot()
        let frame = CGRect(x: 10, y: 0, width: 100, height: 30)
        container.attach(slot, rectangle: frame, native: true)
        container.attach(slot, rectangle: frame, native: true)
        #expect(!container.slotAnimating)
    }
}
