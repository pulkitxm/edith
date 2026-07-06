import AppKit
import EdithKit

struct PixelRulerCapture {
    let cgImage: CGImage
    let buffer: PixelRulerPixelBuffer
}

struct PixelRulerPixelBuffer {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel = 4
    private let bytes: [UInt8]

    init?(cgImage: CGImage) {
        width = cgImage.width
        height = cgImage.height
        bytesPerRow = width * bytesPerPixel
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let base = context.data
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = [UInt8](UnsafeRawBufferPointer(start: base, count: bytesPerRow * height))
    }

    func luminance(x: Int, y: Int) -> Double? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = y * bytesPerRow + x * bytesPerPixel
        return PixelEdgeWalker.luminance(
            r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2])
    }
}

final class PixelRulerOverlayWindow: NSWindow {
    let hostScreen: NSScreen

    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, capture: PixelRulerCapture?, onFinish: @escaping () -> Void) {
        hostScreen = screen
        super.init(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        contentView = PixelRulerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screen: screen, capture: capture, onFinish: onFinish)
        setFrame(screen.frame, display: true)
    }
}

private struct PixelRulerCell {
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int
    var width: Int { right - left }
    var height: Int { bottom - top }
}

final class PixelRulerView: NSView {
    private let hostScreen: NSScreen
    private let capture: PixelRulerCapture?
    private let onFinish: () -> Void
    private let backgroundImage: NSImage?
    private var cursorPoint: NSPoint
    private var dragOrigin: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame: NSRect, screen: NSScreen, capture: PixelRulerCapture?, onFinish: @escaping () -> Void
    ) {
        hostScreen = screen
        self.capture = capture
        self.onFinish = onFinish
        backgroundImage = capture.map { NSImage(cgImage: $0.cgImage, size: frame.size) }
        cursorPoint = NSPoint(x: frame.midX, y: frame.midY)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private var scale: CGFloat { hostScreen.backingScaleFactor }

    private var unit: PixelRulerUnit {
        PixelRulerUnit(rawValue: SharedDefaults.store.string(forKey: "pixelRulerUnit") ?? "")
            ?? .pixels
    }

    private var tolerance: Double {
        SharedDefaults.store.object(forKey: "pixelRulerEdgeTolerance") as? Double ?? 24
    }

    private var loupeZoom: CGFloat {
        CGFloat(SharedDefaults.store.object(forKey: "pixelRulerLoupeZoom") as? Double ?? 8)
    }

    private var copyFormat: PixelRulerCopyFormat {
        PixelRulerCopyFormat(
            rawValue: SharedDefaults.store.string(forKey: "pixelRulerCopyFormat") ?? "")
            ?? .times
    }

    private func devicePoint(_ viewPoint: NSPoint) -> (x: Int, y: Int) {
        (Int((viewPoint.x * scale).rounded()), Int((viewPoint.y * scale).rounded()))
    }

    private func snappedCell(at point: (x: Int, y: Int)) -> PixelRulerCell? {
        guard let capture else { return nil }
        let buffer = capture.buffer
        guard
            let left = PixelEdgeWalker.walk(
                from: point.x, step: -1, tolerance: tolerance,
                sample: { buffer.luminance(x: $0, y: point.y) }),
            let right = PixelEdgeWalker.walk(
                from: point.x, step: 1, tolerance: tolerance,
                sample: { buffer.luminance(x: $0, y: point.y) }),
            let top = PixelEdgeWalker.walk(
                from: point.y, step: -1, tolerance: tolerance,
                sample: { buffer.luminance(x: point.x, y: $0) }),
            let bottom = PixelEdgeWalker.walk(
                from: point.y, step: 1, tolerance: tolerance,
                sample: { buffer.luminance(x: point.x, y: $0) })
        else { return nil }
        return PixelRulerCell(left: left, right: right, top: top, bottom: bottom)
    }

    private func viewRect(left: Int, right: Int, top: Int, bottom: Int) -> NSRect {
        NSRect(
            x: CGFloat(left) / scale, y: CGFloat(top) / scale,
            width: CGFloat(right - left) / scale, height: CGFloat(bottom - top) / scale)
    }

    private func measurementRectAndSize() -> (rect: NSRect, width: Int, height: Int)? {
        if let origin = dragOrigin {
            let originDevice = devicePoint(origin)
            let cursorDevice = devicePoint(cursorPoint)
            let left = min(originDevice.x, cursorDevice.x)
            let right = max(originDevice.x, cursorDevice.x)
            let top = min(originDevice.y, cursorDevice.y)
            let bottom = max(originDevice.y, cursorDevice.y)
            guard right > left || bottom > top else { return snappedCellResult() }
            return (
                viewRect(left: left, right: right, top: top, bottom: bottom), right - left,
                bottom - top
            )
        }
        return snappedCellResult()
    }

    private func snappedCellResult() -> (rect: NSRect, width: Int, height: Int)? {
        guard let cell = snappedCell(at: devicePoint(cursorPoint)) else { return nil }
        return (
            viewRect(left: cell.left, right: cell.right, top: cell.top, bottom: cell.bottom),
            cell.width, cell.height
        )
    }

    private func text(for result: (rect: NSRect, width: Int, height: Int)) -> String {
        let width = PixelGeometry.measurement(devicePixels: result.width, scale: scale, unit: unit)
        let height = PixelGeometry.measurement(
            devicePixels: result.height, scale: scale, unit: unit)
        return copyFormat.string(width: width, height: height)
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        window?.makeKey()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        dragOrigin = cursorPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        if let result = measurementRectAndSize() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(for: result), forType: .string)
        }
        onFinish()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage?.draw(in: bounds)
        if capture == nil {
            NSColor.black.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
        let result = measurementRectAndSize()
        if let result {
            NSColor.systemYellow.setStroke()
            NSBezierPath(rect: result.rect).stroke()
        }
        drawCrosshair()
        drawLoupe()
        if let result {
            drawHUD(text: text(for: result))
        }
    }

    private func drawCrosshair() {
        NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        path.move(to: NSPoint(x: bounds.minX, y: cursorPoint.y))
        path.line(to: NSPoint(x: bounds.maxX, y: cursorPoint.y))
        path.move(to: NSPoint(x: cursorPoint.x, y: bounds.minY))
        path.line(to: NSPoint(x: cursorPoint.x, y: bounds.maxY))
        path.stroke()
    }

    private func drawLoupe() {
        guard let capture else { return }
        let device = devicePoint(cursorPoint)
        let radius = 12
        let cropRect = CGRect(
            x: device.x - radius, y: device.y - radius, width: radius * 2, height: radius * 2)
        guard let cropped = capture.cgImage.cropping(to: cropRect) else { return }
        let side = CGFloat(radius * 2) * loupeZoom
        let loupeRect = NSRect(
            x: cursorPoint.x + 24, y: cursorPoint.y + 24, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: loupeRect, xRadius: 6, yRadius: 6).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            .draw(in: loupeRect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        NSBezierPath(roundedRect: loupeRect, xRadius: 6, yRadius: 6).stroke()
    }

    private func drawHUD(text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let padding: CGFloat = 6
        let rect = NSRect(
            x: cursorPoint.x + 16, y: cursorPoint.y - size.height - padding * 2 - 16,
            width: size.width + padding * 2, height: size.height + padding * 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        text.draw(
            at: NSPoint(x: rect.minX + padding, y: rect.minY + padding), withAttributes: attributes)
    }
}
