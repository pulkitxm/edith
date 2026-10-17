import AppKit
import EdithKit
import GhosttyTerminal
import Observation
import SwiftTerm
import SwiftUI

final class EdithTerminalView: LocalProcessTerminalView, DirectKeyboardInputResponder {
    static let scrollback = 10000

    static func make() -> EdithTerminalView {
        EdithTerminalView(
            frame: .zero, font: nil, options: TerminalOptions(scrollback: scrollback))
    }

    var onFocus: (() -> Void)?
    var dragSelectsOverCapturedMouse = false
    private var heldCapturedClick: NSEvent?

    override func mouseDown(with event: NSEvent) {
        heldCapturedClick = nil
        let commandClick = event.clickCount == 1 && event.modifierFlags.contains(.command)
        if GhosttyTerminalView.capturedPointerDelivery(
            shift: event.modifierFlags.contains(.shift), commandClick: commandClick,
            clickCount: event.clickCount,
            dragSelects: dragSelectsOverCapturedMouse && terminal.mouseMode != .off
                && !terminal.mouseShiftCapture
        ) == .heldClick {
            heldCapturedClick = event
            window?.makeFirstResponder(self)
            if window?.firstResponder === self { onFocus?() }
            return
        }
        window?.makeFirstResponder(self)
        let press = event.clickCount > 1 ? selecting(event) : event
        super.mouseDown(with: press)
        if window?.firstResponder === self { onFocus?() }
    }

    override func mouseDragged(with event: NSEvent) {
        if let down = heldCapturedClick {
            heldCapturedClick = nil
            super.mouseDown(with: selecting(down))
            super.mouseDragged(with: selecting(event))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let down = heldCapturedClick {
            heldCapturedClick = nil
            super.mouseDown(with: down)
            super.mouseUp(with: event)
            return
        }
        super.mouseUp(with: event)
    }

    private func selecting(_ event: NSEvent) -> NSEvent {
        guard dragSelectsOverCapturedMouse, !terminal.mouseShiftCapture else { return event }
        return NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.union(.shift), timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    var focusRequested = false
    private(set) var renderingActive = true
    private(set) var deferredDisplayPasses = 0
    private(set) var reactivationDisplayPasses = 0
    private(set) var hasDeferredDisplay = false
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    private var temporaryDropFiles = Set<URL>()

    deinit {
        TerminalDropPayload(files: [], temporaryFiles: temporaryDropFiles).removeTemporaryFiles()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusRequested, let window else { return }
        focusRequested = false
        window.makeFirstResponder(self)
    }

    func setRenderingActive(_ active: Bool) {
        guard active != renderingActive else { return }
        renderingActive = active
        isHidden = !active
        guard active, hasDeferredDisplay else { return }
        hasDeferredDisplay = false
        reactivationDisplayPasses += 1
        super.needsDisplay = true
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            guard renderingActive || !newValue else {
                deferDisplay()
                return
            }
            super.needsDisplay = newValue
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard renderingActive else {
            deferDisplay()
            return
        }
        super.setNeedsDisplay(invalidRect)
    }

    private func deferDisplay() {
        guard !hasDeferredDisplay else { return }
        hasDeferredDisplay = true
        deferredDisplayPasses += 1
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch command(for: event) {
        case .newline:
            send([0x1b, 0x0d])
            return true
        case .copy:
            copy(self)
            return true
        case .paste:
            if let payload = TerminalDropPayload.files(from: .general) {
                _ = accept(payload)
            } else {
                paste(self)
            }
            return true
        case .none:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard TerminalDropPayload.canRead(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if deliverDroppedFiles(from: sender.draggingPasteboard) { return true }
        if let rawURL = sender.draggingPasteboard.string(forType: .URL), !rawURL.isEmpty {
            send(Array(GhosttyTerminalView.quote(rawURL).utf8))
            return true
        }
        guard let text = sender.draggingPasteboard.string(forType: .string), !text.isEmpty else {
            return super.performDragOperation(sender)
        }
        send(Array(text.utf8))
        return true
    }

    private func deliverDroppedFiles(from pasteboard: NSPasteboard) -> Bool {
        let receivingPromises = TerminalDropPayload.receivePromisedFiles(from: pasteboard) {
            [weak self] payload in
            _ = self?.accept(payload)
        }
        if receivingPromises { return true }
        guard let payload = TerminalDropPayload.files(from: pasteboard) else { return false }
        return accept(payload)
    }

    private func accept(_ payload: TerminalDropPayload) -> Bool {
        if onDropFiles?(payload) == true { return true }
        temporaryDropFiles.formUnion(payload.temporaryFiles)
        send(Array(payload.shellText.utf8))
        return true
    }

    enum DirectCommand {
        case newline
        case copy
        case paste
        case none
    }

    func command(for event: NSEvent) -> DirectCommand {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .shift, event.keyCode == 36 || event.keyCode == 76 {
            return getTerminal().keyboardEnhancementFlags.isEmpty ? .newline : .none
        }
        guard flags == .command else { return .none }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return selectionActive ? .copy : .none
        case "v": return .paste
        default: return .none
        }
    }
}
