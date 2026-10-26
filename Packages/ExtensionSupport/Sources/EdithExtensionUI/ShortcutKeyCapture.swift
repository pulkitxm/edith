import AppKit
import SwiftUI

public struct ShortcutKeyCapture: NSViewRepresentable {
    @Binding private var recording: Bool
    private let handle: (NSEvent) -> Void

    public init(recording: Binding<Bool>, handle: @escaping (NSEvent) -> Void) {
        _recording = recording
        self.handle = handle
    }

    public func makeNSView(context: Context) -> CaptureView { CaptureView() }

    public func updateNSView(_ view: CaptureView, context: Context) {
        view.handle = handle
        let recording = $recording
        view.cancel = { recording.wrappedValue = false }
        view.active = recording.wrappedValue
        if view.active, let window = view.window, window.firstResponder !== view {
            window.makeFirstResponder(view)
        } else if !view.active, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    public static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.endRecording()
        view.handle = nil
        view.cancel = nil
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }

    public final class CaptureView: NSView {
        var active = false
        var handle: ((NSEvent) -> Void)?
        var cancel: (() -> Void)?
        public override var acceptsFirstResponder: Bool { true }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if active, let window { window.makeFirstResponder(self) }
            if window == nil { endRecording() }
        }

        public override func resignFirstResponder() -> Bool {
            endRecording()
            return true
        }

        public override func keyDown(with event: NSEvent) {
            guard active else { super.keyDown(with: event); return }
            handle?(event)
        }

        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard active, window?.firstResponder === self else {
                return super.performKeyEquivalent(with: event)
            }
            handle?(event)
            return true
        }

        func endRecording() {
            guard active else { return }
            active = false
            let cancel = cancel
            DispatchQueue.main.async { cancel?() }
        }
    }
}
