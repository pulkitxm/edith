import AppKit
import Testing

@testable import EdithExtensionUI

@MainActor @Suite
struct InputFocusTests {
    private final class EmbeddedKeyboardView: NSView, DirectKeyboardInputResponder {}

    @Test func plainLettersStartTypeAheadWhileShortcutsAndEmbeddedEditorsKeepTheirInput() {
        #expect(InputFocus.isTypeAheadKey(characters: "a", modifiers: []))
        #expect(InputFocus.isTypeAheadKey(characters: "Z", modifiers: [.shift]))
        #expect(!InputFocus.isTypeAheadKey(characters: "7", modifiers: []))
        #expect(!InputFocus.isTypeAheadKey(characters: "é", modifiers: []))
        #expect(!InputFocus.isTypeAheadKey(characters: "a", modifiers: [.command]))
        #expect(
            !InputFocus.shouldStartTypeAhead(
                characters: "a", modifiers: [], responder: EmbeddedKeyboardView()))
    }

    @Test func typeAheadOnlyTargetsTheOwningWindowAndUnregistersOnRemoval() {
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100))
        defer { window.orderOut(nil) }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 220, height: 28))
        let anchor = NSView(frame: field.frame)
        root.addSubview(field); root.addSubview(anchor)
        window.contentView = root
        TypeAhead.shared.register(anchor: anchor)
        defer { TypeAhead.shared.unregister(anchor: anchor) }
        #expect(TypeAhead.shared.focusField(in: window))
        let other = TestWindowHost.window(contentRect: root.frame)
        defer { other.orderOut(nil) }
        #expect(!TypeAhead.shared.focusField(in: other))
        TypeAhead.shared.unregister(anchor: anchor)
        #expect(!TypeAhead.shared.focusField(in: window))
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }
}
