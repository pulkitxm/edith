import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@testable import EdithHost

@Suite(.serialized) @MainActor struct ShortcutKeyCaptureTests {
    @Test(arguments: [false, true])
    func captureEndsWhenItsNativeViewDetaches(replaceRoot: Bool) async throws {
        _ = TestWindowHost.application
        let state = CaptureState()
        let host = NSHostingView(rootView: AnyView(capture(state)))
        let window = CaptureWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let view = try #require(findCapture(in: host))
        #expect(window.firstResponder === view)
        #expect(view.performKeyEquivalent(with: event(window)))
        #expect(state.events == 1)
        if replaceRoot { host.rootView = AnyView(Color.clear) } else { host.removeFromSuperview() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!view.performKeyEquivalent(with: event(window)))
        #expect(state.events == 1)
        #expect(!state.recording)
    }

    @Test func captureEndsWhenFocusMovesToAnotherControl() async throws {
        _ = TestWindowHost.application
        let state = CaptureState()
        let host = NSHostingView(rootView: capture(state))
        let window = CaptureWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let view = try #require(findCapture(in: host))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        host.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!view.performKeyEquivalent(with: event(window)))
        #expect(state.events == 0)
        #expect(!state.recording)
    }

    private func capture(_ state: CaptureState) -> some View {
        ShortcutKeyCapture(
            recording: Binding(get: { state.recording }, set: { state.recording = $0 }),
            handle: { _ in state.events += 1 })
    }

    private func findCapture(in view: NSView) -> ShortcutKeyCapture.CaptureView? {
        if let capture = view as? ShortcutKeyCapture.CaptureView { return capture }
        for child in view.subviews {
            if let capture = findCapture(in: child) { return capture }
        }
        return nil
    }

    private func event(_ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false,
            keyCode: 8)!
    }
}

@MainActor private final class CaptureState {
    var recording = true
    var events = 0
}

@MainActor private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
