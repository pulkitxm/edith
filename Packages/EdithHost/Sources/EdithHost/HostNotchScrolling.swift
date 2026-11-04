import AppKit
import ObjectiveC

enum HostNotchScrollAxis: Equatable {
    case horizontal, vertical

    init?(deltaX: CGFloat, deltaY: CGFloat) {
        guard deltaX != 0 || deltaY != 0 else { return nil }
        self = abs(deltaX) > abs(deltaY) ? .horizontal : .vertical
    }
}

@MainActor
final class HostNotchScrollRouter {
    typealias Resolve = @MainActor (CGPoint, HostNotchScrollAxis) -> NSView?
    typealias Deliver = @MainActor (NSEvent, NSView?) -> Void

    private weak var target: NSView?
    private var resolved = false
    private var pending: [NSEvent] = []

    func route(_ event: NSEvent, resolve: Resolve, deliver: Deliver) {
        if !event.momentumPhase.isEmpty {
            deliver(event, resolved ? target : nil)
            if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) { reset(deliver) }
            return
        }
        if event.phase.isEmpty {
            reset(deliver)
            let axis = HostNotchScrollAxis(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            deliver(event, axis.flatMap { resolve(event.locationInWindow, $0) })
            return
        }
        if event.phase.contains(.mayBegin) || (event.phase.contains(.began) && resolved) {
            reset(deliver)
        }
        if resolved {
            deliver(event, target)
            return
        }
        pending.append(event)
        let axis = HostNotchScrollAxis(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        guard axis != nil || !event.phase.isDisjoint(with: [.ended, .cancelled]) else { return }
        resolved = true
        let chosen = axis.flatMap { resolve(event.locationInWindow, $0) }
        target = chosen
        let queued = pending
        pending = []
        for event in queued { deliver(event, chosen) }
    }

    private func reset(_ deliver: Deliver) {
        let queued = pending
        pending = []
        target = nil
        resolved = false
        for event in queued { deliver(event, nil) }
    }
}

enum HostNotchScrollOwner {
    case scroller(NSScrollView)
    case view
    case none

    @MainActor
    static func find(
        from view: NSView, axis: HostNotchScrollAxis, boundary: NSView
    ) -> HostNotchScrollOwner {
        var current: NSView? = view
        while let candidate = current, candidate !== boundary {
            if let scroller = candidate as? NSScrollView {
                if scroller.scrolls(along: axis) { return .scroller(scroller) }
            } else if handlesScrollWheel(candidate) {
                return .view
            }
            current = candidate.superview
        }
        return .none
    }

    @MainActor
    private static func handlesScrollWheel(_ view: NSView) -> Bool {
        guard !String(reflecting: type(of: view)).hasPrefix("SwiftUI.") else { return false }
        let selector = #selector(NSResponder.scrollWheel(with:))
        return class_getMethodImplementation(type(of: view), selector)
            != class_getMethodImplementation(NSView.self, selector)
    }
}

extension NSScrollView {
    func scrolls(along axis: HostNotchScrollAxis) -> Bool {
        guard let documentView else { return false }
        let visible = contentView.bounds.size
        let extent = documentView.frame.size
        switch axis {
        case .vertical: return extent.height - visible.height > 0.5
        case .horizontal: return extent.width - visible.width > 0.5
        }
    }
}

enum HostNotchSlotAnchor {
    static let prefix = "edith.notch.slot."
    static let appeared = Notification.Name("edith.notch.slot.anchor")

    static func identifier(kind: String, providerID: String, tileID: String) -> String {
        prefix + kind + ":" + providerID + ":" + tileID
    }

    @MainActor
    static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for subview in view.subviews {
            if let found = find(identifier, in: subview) { return found }
        }
        return nil
    }
}

@MainActor
final class HostNotchSlotClip: NSView {
    override var isFlipped: Bool { true }
    var anchorIdentifier: String?
    private(set) weak var anchor: NSView?
    private var observations: [NSObjectProtocol] = []

    var following: Bool { anchor?.window != nil && anchor?.window === window }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }

    func follow(_ next: NSView?, below boundary: NSView) {
        if let next, next === anchor, !observations.isEmpty {
            place()
            return
        }
        stopFollowing()
        anchor = next
        guard let next else { return }
        var current: NSView? = next
        let center = NotificationCenter.default
        while let view = current, view !== boundary {
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                observations.append(
                    center.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
            }
            view.postsFrameChangedNotifications = true
            observations.append(
                center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: nil
                ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
            current = view.superview
        }
        place()
    }

    func stopFollowing() {
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations = []
        anchor = nil
    }

    func place() {
        guard let anchor, let host = superview, following else { return }
        let shown = anchor.visibleRect.intersection(anchor.bounds)
        guard !shown.isNull, !shown.isEmpty else {
            isHidden = true
            return
        }
        let visible = anchor.convert(shown, to: host)
        isHidden = false
        layer?.removeAnimation(forKey: HostNotchSlotClip.glideKey)
        if frame != visible { frame = visible }
        let card = anchor.convert(anchor.bounds, to: self)
        for subview in subviews where subview.frame != card { subview.frame = card }
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subviews == [subview] else { return }
        stopFollowing()
        removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    static let glideKey = "slotGlide"
}
