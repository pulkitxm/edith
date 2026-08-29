import AppKit
import EdithKit
import ScreenCaptureKit

@MainActor
final class ScreenRecordingSourceSelector {
    private var overlay: ScreenRecordingAreaPanel?

    func select(_ source: ScreenRecordingSource) async throws -> ScreenRecordingRegion {
        switch source {
        case .area:
            try await selectArea()
        case .window:
            try await selectWindow()
        case .display:
            try await selectDisplay()
        }
    }

    func cancel() {
        overlay?.finish(nil)
        overlay = nil
    }

    private func selectArea() async throws -> ScreenRecordingRegion {
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main ?? NSScreen.screens.first,
            let displayID = Self.displayID(screen)
        else { throw ScreenRecordingError.sourceUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let panel = ScreenRecordingAreaPanel(screen: screen) { [weak self] rect in
                self?.overlay = nil
                guard let rect, rect.width >= 32, rect.height >= 32 else {
                    continuation.resume(throwing: ScreenRecordingError.cancelled)
                    return
                }
                let scale = screen.backingScaleFactor
                let local = CGRect(
                    x: rect.minX - screen.frame.minX,
                    y: screen.frame.maxY - rect.maxY,
                    width: rect.width, height: rect.height)
                continuation.resume(
                    returning: ScreenRecordingRegion(
                        source: .area, displayID: displayID,
                        sourceRect: local,
                        pixelSize: CGSize(
                            width: floor(rect.width * scale / 2) * 2,
                            height: floor(rect.height * scale / 2) * 2),
                        anchorRect: rect, scale: scale))
            }
            overlay = panel
            panel.show()
        }
    }

    private func selectWindow() async throws -> ScreenRecordingRegion {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownProcess = NSRunningApplication.current.processIdentifier
        let windows = await Task.detached(priority: .userInitiated) {
            content.windows.filter {
                $0.owningApplication?.processID != ownProcess && $0.frame.width >= 32
                    && $0.frame.height >= 32
            }.sorted {
                let lhs = $0.owningApplication?.applicationName ?? ""
                let rhs = $1.owningApplication?.applicationName ?? ""
                return lhs == rhs ? ($0.title ?? "") < ($1.title ?? "") : lhs < rhs
            }
        }.value
        guard !windows.isEmpty else { throw ScreenRecordingError.sourceUnavailable }
        let labels = windows.map {
            let app = $0.owningApplication?.applicationName ?? "Application"
            let title = ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? app : "\(app): \(title)"
        }
        guard
            let index = choose(
                title: "Record a window", message: "Choose the window to record.", labels: labels)
        else { throw ScreenRecordingError.cancelled }
        let window = windows[index]
        let screen = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(window.frame).area < rhs.frame.intersection(window.frame).area
        }
        guard let screen, let displayID = Self.displayID(screen) else {
            throw ScreenRecordingError.sourceUnavailable
        }
        let scale = screen.backingScaleFactor
        return ScreenRecordingRegion(
            source: .window, displayID: displayID, windowID: window.windowID,
            sourceRect: .zero,
            pixelSize: CGSize(
                width: floor(window.frame.width * scale / 2) * 2,
                height: floor(window.frame.height * scale / 2) * 2),
            anchorRect: window.frame, scale: scale)
    }

    private func selectDisplay() async throws -> ScreenRecordingRegion {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let displays = await Task.detached(priority: .userInitiated) {
            content.displays.sorted { $0.displayID < $1.displayID }
        }.value
        guard !displays.isEmpty else { throw ScreenRecordingError.sourceUnavailable }
        let labels = displays.enumerated().map { index, display in
            let screen = NSScreen.screens.first { Self.displayID($0) == display.displayID }
            let name = screen?.localizedName ?? "Display \(index + 1)"
            return "\(name), \(display.width) × \(display.height)"
        }
        let index: Int
        if displays.count == 1 {
            index = 0
        } else if let selected = choose(
            title: "Record a display", message: "Choose the display to record.", labels: labels)
        {
            index = selected
        } else {
            throw ScreenRecordingError.cancelled
        }
        let display = displays[index]
        guard
            let screen = NSScreen.screens.first(where: {
                Self.displayID($0) == display.displayID
            })
        else { throw ScreenRecordingError.sourceUnavailable }
        return ScreenRecordingRegion(
            source: .display, displayID: display.displayID,
            sourceRect: CGRect(origin: .zero, size: screen.frame.size),
            pixelSize: CGSize(width: display.width, height: display.height),
            anchorRect: screen.frame, scale: screen.backingScaleFactor)
    }

    private func choose(title: String, message: String, labels: [String]) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        picker.addItems(withTitles: labels)
        alert.accessoryView = picker
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? picker.indexOfSelectedItem : nil
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

private final class ScreenRecordingAreaPanel: NSPanel {
    private let completed: (CGRect?) -> Void
    private var localMonitor: Any?
    private var finished = false

    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, completed: @escaping (CGRect?) -> Void) {
        self.completed = completed
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        let view = ScreenRecordingAreaView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.complete = { [weak self] rect in self?.finish(rect) }
        contentView = view
    }

    func show() {
        orderFrontRegardless()
        makeKey()
        NSCursor.crosshair.set()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 { self?.finish(nil); return nil }
            return event
        }
    }

    func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        NSCursor.arrow.set()
        close()
        completed(rect)
    }
}

private final class ScreenRecordingAreaView: NSView {
    var complete: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var selection = CGRect.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(startPoint.x, current.x), y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x), height: abs(current.y - startPoint.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard selection.width >= 32, selection.height >= 32,
            let window
        else { complete?(nil); return }
        complete?(window.convertToScreen(selection))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        guard !selection.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(rect: bounds)
        path.appendRect(selection)
        path.windingRule = .evenOdd
        NSColor.clear.setFill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.copy)
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: selection, xRadius: 6, yRadius: 6)
        outline.lineWidth = 2
        outline.stroke()
        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        label.draw(
            at: CGPoint(x: selection.minX + 8, y: max(8, selection.minY - 24)),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
