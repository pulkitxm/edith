import AppKit
import Testing

@testable import EdithKit

@MainActor
@Suite struct InputFocusTests {
    private final class DirectScrollView: NSView, DirectScrollHandling {}

    @Test func plainLettersStartTypeAhead() {
        #expect(InputFocus.isTypeAheadKey(characters: "a", modifiers: []))
        #expect(InputFocus.isTypeAheadKey(characters: "Z", modifiers: [.shift]))
    }

    @Test func digitsShortcutsAndNonAsciiDoNot() {
        #expect(!InputFocus.isTypeAheadKey(characters: "7", modifiers: []))
        #expect(!InputFocus.isTypeAheadKey(characters: " ", modifiers: []))
        #expect(!InputFocus.isTypeAheadKey(characters: "é", modifiers: []))
        #expect(!InputFocus.isTypeAheadKey(characters: "a", modifiers: [.command]))
        #expect(!InputFocus.isTypeAheadKey(characters: nil, modifiers: []))
    }

    @Test func commandFSelectsTheVisibleSearchAndSkipsUnavailableFields() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 28))
        field.stringValue = "sample query"
        let anchor = NSView(frame: field.frame)
        let disabled = NSTextField(frame: NSRect(x: 20, y: 80, width: 200, height: 28))
        disabled.isEnabled = false
        let disabledAnchor = NSView(frame: disabled.frame)
        for view in [field, anchor, disabled, disabledAnchor] { root.addSubview(view) }
        let window = TestWindowHost.window(contentRect: root.frame)
        window.contentView = root
        window.orderBack(nil)
        defer {
            TypeAhead.shared.unregister(anchor: anchor)
            TypeAhead.shared.unregister(anchor: disabledAnchor)
            window.orderOut(nil)
        }
        TypeAhead.shared.register(anchor: anchor, typeAhead: false)
        TypeAhead.shared.register(anchor: disabledAnchor, typeAhead: false)
        #expect(!TypeAhead.shared.focusField(in: window, typeAheadOnly: true))
        #expect(TypeAhead.shared.focusField(in: window, selectAll: true))
        let editor = try #require(field.currentEditor())
        #expect(editor.selectedRange == NSRange(location: 0, length: field.stringValue.count))
        #expect(disabled.currentEditor() == nil)
        #expect(InputFocus.isSearchShortcut(characters: "f", modifiers: .command))
        #expect(!InputFocus.isSearchShortcut(characters: "f", modifiers: [.command, .shift]))
        #expect(!InputFocus.isSearchShortcut(characters: "f", modifiers: []))
    }

    @Test func onlyOverflowingContentScrolls() {
        #expect(ScrollForwarding.scrollsVertically(content: 900, visible: 400))
        #expect(!ScrollForwarding.scrollsVertically(content: 400, visible: 400))
    }

    @Test func aGestureIsRetargetedOnlyAtItsStart() {
        #expect(ScrollForwarding.startsGesture(phase: .began, momentum: []))
        #expect(ScrollForwarding.startsGesture(phase: [], momentum: []))
        #expect(!ScrollForwarding.startsGesture(phase: .changed, momentum: []))
        #expect(!ScrollForwarding.startsGesture(phase: [], momentum: .changed))
    }

    @Test func aFlatGestureStillCountsAsVertical() {
        #expect(ScrollForwarding.carriesVerticalScroll(deltaX: 0, deltaY: 0))
        #expect(ScrollForwarding.carriesVerticalScroll(deltaX: 1, deltaY: 4))
        #expect(!ScrollForwarding.carriesVerticalScroll(deltaX: 4, deltaY: 1))
    }

    @Test func aDirectScrollHandlerAndItsDescendantsAreNeverRetargeted() {
        let direct = DirectScrollView()
        let child = NSView()
        direct.addSubview(child)

        #expect(ScrollForwarding.handlesScrollDirectly(from: direct))
        #expect(ScrollForwarding.handlesScrollDirectly(from: child))
        #expect(!ScrollForwarding.handlesScrollDirectly(from: NSView()))
    }
}
