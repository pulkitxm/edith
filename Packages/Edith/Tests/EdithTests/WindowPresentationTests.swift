import AppKit
import Testing

@testable import EdithKit

@MainActor
@Suite struct WindowPresentationTests {
    @Test func presentationSkipsOrderingInBackgroundMode() {
        let window = hiddenWindow()
        var ordered = false
        var activated = false
        var fronted = false
        WindowPresentation.makeKeyAndOrderFront(window, suppressed: true) { _ in ordered = true }
        WindowPresentation.activate(suppressed: true) { activated = true }
        WindowPresentation.orderFront(window, suppressed: true) { _ in fronted = true }
        WindowPresentation.orderFrontRegardless(window, suppressed: true) { _ in fronted = true }
        #expect(!ordered)
        #expect(!activated)
        #expect(!fronted)
        #expect(!window.isVisible)
    }

    @Test func presentationOrdersWhenBackgroundModeIsOff() {
        let window = hiddenWindow()
        var ordered = false
        var activated = false
        WindowPresentation.makeKeyAndOrderFront(window, suppressed: false) { _ in ordered = true }
        WindowPresentation.activate(suppressed: false) { activated = true }
        #expect(ordered)
        #expect(activated)
        #expect(!window.isVisible)
    }

    private func hiddenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled], backing: .buffered, defer: true)
    }
}
