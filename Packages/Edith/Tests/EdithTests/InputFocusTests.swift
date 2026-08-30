import AppKit
import EdithKit
import Testing

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
