import AppKit
import EdithKit
import Testing

@MainActor
@Suite struct InputFocusTests {
    @Test func escapeWithoutModifiersUnfocuses() {
        #expect(InputFocus.escapeUnfocuses(keyCode: InputFocus.escapeKeyCode, modifiers: []))
    }

    @Test func escapeWithModifiersIsLeftAlone() {
        #expect(
            !InputFocus.escapeUnfocuses(keyCode: InputFocus.escapeKeyCode, modifiers: [.command]))
        #expect(!InputFocus.escapeUnfocuses(keyCode: 36, modifiers: []))
    }

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

    @Test func onlyOverflowingContentScrolls() {
        #expect(ScrollForwarding.scrollsVertically(content: 900, visible: 400))
        #expect(!ScrollForwarding.scrollsVertically(content: 400, visible: 400))
    }
}
