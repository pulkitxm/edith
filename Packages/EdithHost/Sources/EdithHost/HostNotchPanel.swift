import AppKit
import EdithExtensionUI
import QuartzCore

@MainActor
final class HostNotchPanel: NSPanel {
    var acceptsKeyFocus = false
    var transferEvent: NSEvent?
    private let scrolling = HostNotchScrollRouter()

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseDragged].contains(event.type), event.window === self {
            transferEvent = event
        }
        guard event.type == .scrollWheel,
            let container = contentViewController as? HostNotchContainerController
        else {
            super.sendEvent(event)
            return
        }
        scrolling.route(event, resolve: { container.scrollTarget(at: $0, axis: $1) }) {
            event, target in
            if let target {
                target.scrollWheel(with: event)
            } else {
                super.sendEvent(event)
            }
        }
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
        nativeLayer.frame = view.bounds
        nativeLayer.autoresizingMask = [.width, .height]
        view.addSubview(nativeLayer)
        anchorObservation = NotificationCenter.default.addObserver(
            forName: HostNotchSlotAnchor.appeared, object: nil, queue: nil
        ) { [weak self] note in
            guard let anchor = note.object as? NSView else { return }
            MainActor.assumeIsolated { self?.anchorAppeared(anchor) }
        }
    }

    private var anchorObservation: NSObjectProtocol?

    func scrollTarget(at windowPoint: CGPoint, axis: HostNotchScrollAxis) -> NSView? {
        guard isViewLoaded else { return nil }
        let point = root.convert(windowPoint, from: nil)
        if let card = nativeLayer.hitTest(point) {
            switch HostNotchScrollOwner.find(from: card, axis: axis, boundary: nativeLayer) {
            case .scroller(let scroller): return scroller
            case .view: return nil
            case .none: break
            }
        }
        for chrome in root.subviews.reversed() where chrome !== nativeLayer {
            guard let hit = chrome.hitTest(point) else { continue }
            if case .scroller(let scroller) = HostNotchScrollOwner.find(
                from: hit, axis: axis, boundary: root)
            {
                return scroller
            }
            return nil
        }
        return nil
    }

    func attach(
        _ controller: NSViewController, rectangle: CGRect?, native: Bool, anchor: String? = nil
    ) {
        loadViewIfNeeded()
        if controller.parent !== self { addChild(controller) }
        guard native else {
            if controller.view.superview !== root {
                root.addSubview(controller.view, positioned: .below, relativeTo: nativeLayer)
            }
            controller.view.frame = rectangle ?? view.bounds
            controller.view.autoresizingMask = [.width, .height]
            return
        }
        let card = controller.view
        let existing = card.superview as? HostNotchSlotClip
        let clip =
            existing.flatMap { $0.superview === nativeLayer ? $0 : nil } ?? HostNotchSlotClip()
        if clip.superview !== nativeLayer {
            nativeLayer.addSubview(clip)
            clip.addSubview(card)
        }
        clip.anchorIdentifier = anchor
        let target = rectangle ?? view.bounds
        if let anchor, let found = anchorView(anchor) {
            clip.follow(found, below: root)
            return
        }
        clip.stopFollowing()
        clip.isHidden = false
        let wasPlaced = existing === clip && clip.frame != target
        let layer = wasPlaced ? clip.layer : nil
        let fromPosition = layer.map { $0.presentation()?.position ?? $0.position }
        let fromBounds = layer.map { $0.presentation()?.bounds ?? $0.bounds }
        clip.frame = target
        card.frame = clip.bounds
        card.autoresizingMask = [.width, .height]
        guard wasPlaced, let layer, let fromPosition, let fromBounds else { return }
        layer.removeAnimation(forKey: HostNotchSlotClip.glideKey)
        let group = CAAnimationGroup()
        let position = glide.animation(
            keyPath: "position", from: NSValue(point: fromPosition),
            to: NSValue(point: layer.position))
        let bounds = glide.animation(
            keyPath: "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds))
        group.animations = [position, bounds]
        group.duration = max(position.duration, bounds.duration)
        layer.add(group, forKey: HostNotchSlotClip.glideKey)
    }

    func placedFrame(of controller: NSViewController) -> CGRect? {
        guard controller.isViewLoaded, let clip = controller.view.superview as? HostNotchSlotClip,
            clip.superview === nativeLayer
        else { return nil }
        return controller.view.convert(controller.view.bounds, to: root)
    }

    private func anchorView(_ identifier: String) -> NSView? {
        for chrome in root.subviews where chrome !== nativeLayer {
            if let found = HostNotchSlotAnchor.find(identifier, in: chrome) { return found }
        }
        return nil
    }

    private func anchorAppeared(_ anchor: NSView) {
        guard isViewLoaded, anchor.isDescendant(of: root), !anchor.isDescendant(of: nativeLayer),
            let identifier = anchor.identifier?.rawValue
        else { return }
        for case let clip as HostNotchSlotClip in nativeLayer.subviews
        where clip.anchorIdentifier == identifier && clip.anchor !== anchor {
            clip.follow(anchor, below: root)
        }
    }

    var slotAnimating: Bool {
        nativeLayer.subviews.contains {
            $0.layer?.animation(forKey: HostNotchSlotClip.glideKey) != nil
        }
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
