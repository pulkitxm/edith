import AppKit
import QuartzCore

@MainActor
final class HostNotchPanel: NSPanel {
    var acceptsKeyFocus = false
    var transferEvent: NSEvent?

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseDragged].contains(event.type), event.window === self {
            transferEvent = event
        }
        super.sendEvent(event)
    }
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
    private let root = HostNotchFlippedView()
    private let mask = CAShapeLayer()
    var drop: (@MainActor (HostNotchDropInput, CGPoint) -> Bool)? {
        didSet { root.drop = drop }
    }
    var dragging: (@MainActor (CGPoint, Bool) -> Void)? {
        didSet { root.dragging = dragging }
    }

    override func loadView() {
        view = root
        root.registerForDraggedTypes(
            [.fileURL, .string]
                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        )
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

    func apply(_ state: HostNotchPanelState, size: CGSize) {
        loadViewIfNeeded()
        view.frame.size = size
        nativeLayer.frame = view.bounds
        mask.frame = nativeLayer.bounds
        let top: CGFloat = state.phase == .collapsed ? 0 : 10
        let bottom: CGFloat = state.phase == .expanded ? 22 : state.phase == .alert ? 20 : 12
        let rect = CGRect(
            x: (size.width - state.shapeWidth) / 2, y: 0,
            width: state.shapeWidth, height: state.shapeHeight)
        root.interactiveRectangle = rect
        nativeLayer.interactiveRectangle = rect
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
    var interactiveRectangle: CGRect?
    var drop: (@MainActor (HostNotchDropInput, CGPoint) -> Bool)?
    var dragging: (@MainActor (CGPoint, Bool) -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender { dragging?(sender.draggingLocation, false) }
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragging?(sender.draggingLocation, false)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard let rect = interactiveRectangle, rect.insetBy(dx: -24, dy: -24).contains(point) else {
            return false
        }
        return drop?(
            HostNotchDropInput.read(sender.draggingPasteboard),
            CGPoint(x: point.x - rect.minX, y: point.y)) ?? false
    }
    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard drop != nil, let rect = interactiveRectangle,
            rect.insetBy(dx: -24, dy: -24).contains(convert(sender.draggingLocation, from: nil))
        else { return [] }
        dragging?(sender.draggingLocation, true)
        return .copy
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let interactiveRectangle,
            !interactiveRectangle.contains(convert(point, from: superview))
        {
            return nil
        }
        return super.hitTest(point)
    }
}

private final class HostNotchPassthroughView: HostNotchFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
