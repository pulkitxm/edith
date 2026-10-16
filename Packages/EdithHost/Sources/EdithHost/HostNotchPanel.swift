import AppKit
import EdithExtensionUI
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if TextEditingCommands.handle(event) { return true }
        return super.performKeyEquivalent(with: event)
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
    private var glide = HostNotchGlide.resolve(
        reduceMotion: false, browser: false, expanded: false)
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
        let alreadyPlaced = controller.view.superview === container
        if controller.view.superview !== container {
            if native {
                container.addSubview(controller.view)
            } else {
                container.addSubview(controller.view, positioned: .below, relativeTo: nativeLayer)
            }
        }
        let target = rectangle ?? view.bounds
        let slot = controller.view
        if native { slot.wantsLayer = true }
        let wasPlaced = native && alreadyPlaced && slot.frame != target
        let layer = wasPlaced ? slot.layer : nil
        let fromPosition = layer.map { $0.presentation()?.position ?? $0.position }
        let fromBounds = layer.map { $0.presentation()?.bounds ?? $0.bounds }
        slot.frame = target
        slot.autoresizingMask = native ? [] : [.width, .height]
        guard wasPlaced, let layer, let fromPosition, let fromBounds else { return }
        layer.removeAnimation(forKey: "slotGlide")
        let group = CAAnimationGroup()
        let position = glide.animation(
            keyPath: "position", from: NSValue(point: fromPosition),
            to: NSValue(point: layer.position))
        let bounds = glide.animation(
            keyPath: "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds))
        group.animations = [position, bounds]
        group.duration = max(position.duration, bounds.duration)
        layer.add(group, forKey: "slotGlide")
    }

    var slotAnimating: Bool {
        nativeLayer.subviews.contains { $0.layer?.animation(forKey: "slotGlide") != nil }
    }

    func apply(_ state: HostNotchPanelState, size: CGSize) {
        loadViewIfNeeded()
        view.frame.size = size
        nativeLayer.frame = view.bounds
        nativeLayer.interactionEnabled = state.layoutEditing != true
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
        let previous = mask.presentation()?.path ?? mask.path
        mask.path = path
        glide = HostNotchGlide.resolve(
            reduceMotion: HostNotchMotion.reduceMotion, browser: state.activeTab == "browser",
            expanded: state.phase == .expanded)
        if let previous, previous != path {
            mask.add(glide.animation(keyPath: "path", from: previous, to: path), forKey: "glide")
        }
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
    var interactionEnabled = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactionEnabled else { return nil }
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
