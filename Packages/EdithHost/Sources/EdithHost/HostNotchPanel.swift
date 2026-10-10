import AppKit
import QuartzCore

@MainActor
final class HostNotchPanel: NSPanel {
    var acceptsKeyFocus = false
    override var canBecomeKey: Bool { acceptsKeyFocus }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }
}

@MainActor
final class HostNotchContainerController: NSViewController {
    private let nativeLayer = HostNotchPassthroughView()
    private let mask = CAShapeLayer()

    override func loadView() {
        view = HostNotchFlippedView()
        nativeLayer.wantsLayer = true
        nativeLayer.layer?.mask = mask
        view.addSubview(nativeLayer)
    }

    func attach(_ controller: NSViewController, rectangle: CGRect?, native: Bool) {
        loadViewIfNeeded()
        if controller.parent !== self { addChild(controller) }
        let container = native ? nativeLayer : view
        if controller.view.superview !== container {
            if native {
                container.addSubview(controller.view)
            } else {
                container.addSubview(controller.view, positioned: .below, relativeTo: nativeLayer)
            }
        }
        controller.view.frame = rectangle ?? view.bounds
        controller.view.autoresizingMask = native ? [] : [.width, .height]
    }

    func apply(_ state: HostNotchPanelState) {
        loadViewIfNeeded()
        view.frame.size = state.panelSize
        nativeLayer.frame = view.bounds
        mask.frame = nativeLayer.bounds
        let top: CGFloat = state.phase == .collapsed ? 0 : 10
        let bottom: CGFloat = state.phase == .expanded ? 22 : state.phase == .alert ? 20 : 12
        let rect = CGRect(
            x: (state.panelSize.width - state.shapeWidth) / 2, y: 0,
            width: state.shapeWidth, height: state.shapeHeight)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        mask.path = path
    }
}

private class HostNotchFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class HostNotchPassthroughView: HostNotchFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
