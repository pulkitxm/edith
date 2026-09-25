import AppKit
import CoreVideo
import EdithKit
import SwiftUI

final class VirtualCameraPreviewDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var scheduled = false
    @MainActor private(set) var current: CVPixelBuffer?
    @MainActor weak var view: VirtualCameraPreviewNSView?

    func push(_ buffer: CVPixelBuffer) {
        let shouldSchedule = lock.withLock { () -> Bool in
            pending = buffer
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    @MainActor func flush() {
        let next = lock.withLock { () -> CVPixelBuffer? in
            scheduled = false
            let next = pending
            pending = nil
            return next
        }
        guard let next else { return }
        current = next
        view?.show(next)
    }

    @MainActor func clear() {
        lock.withLock { pending = nil }
        current = nil
        view?.show(nil)
    }
}

final class VirtualCameraPreviewNSView: NSView {
    var onPan: ((CGSize, CGSize) -> Void)?
    var onZoom: ((Double, CGPoint) -> Void)?
    var onReset: (() -> Void)?
    var aspectRatio: CGFloat = 16.0 / 9.0 {
        didSet { needsLayout = true }
    }
    var mirrored = false {
        didSet { applyMirror() }
    }
    private let content = CALayer()
    private var lastDrag: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        content.contentsGravity = .resizeAspect
        content.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var pictureRect: CGRect {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0, aspectRatio > 0 else { return .zero }
        var width = bounds.width
        var height = width / aspectRatio
        if height > bounds.height {
            height = bounds.height
            width = height * aspectRatio
        }
        return CGRect(
            x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = pictureRect
        CATransaction.commit()
    }

    func show(_ buffer: CVPixelBuffer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = buffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
        CATransaction.commit()
    }

    private func applyMirror() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(pictureRect, cursor: lastDrag == nil ? .openHand : .closedHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            onReset?()
            lastDrag = nil
            return
        }
        lastDrag = convert(event.locationInWindow, from: nil)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let last = lastDrag else { return }
        lastDrag = point
        let delta = CGSize(
            width: (point.x - last.x) * (mirrored ? -1 : 1), height: -(point.y - last.y))
        onPan?(delta, pictureRect.size)
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
        window?.invalidateCursorRects(for: self)
    }

    func anchor(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return Self.anchor(of: point, in: pictureRect, mirrored: mirrored)
    }

    static func anchor(of point: CGPoint, in rect: CGRect, mirrored: Bool) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max(1 - (point.y - rect.minY) / rect.height, 0), 1)
        return CGPoint(x: mirrored ? 1 - x : x, y: y)
    }

    static func zoomFactor(scrollDelta: CGFloat, precise: Bool) -> Double {
        exp(Double(scrollDelta) * (precise ? 0.008 : 0.08))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        onZoom?(
            Self.zoomFactor(scrollDelta: delta, precise: event.hasPreciseScrollingDeltas),
            anchor(for: event))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + Double(event.magnification), anchor(for: event))
    }
}

struct VirtualCameraPreview: NSViewRepresentable {
    let display: VirtualCameraPreviewDisplay
    let mirrored: Bool
    let onPan: (CGSize, CGSize) -> Void
    let onZoom: (Double, CGPoint) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> VirtualCameraPreviewNSView {
        let view = VirtualCameraPreviewNSView(frame: .zero)
        display.view = view
        view.show(display.current)
        return view
    }

    func updateNSView(_ view: VirtualCameraPreviewNSView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onReset = onReset
        view.mirrored = mirrored
        if display.view !== view {
            display.view = view
            view.show(display.current)
        }
    }
}
