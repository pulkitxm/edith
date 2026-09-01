import Foundation
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyAccessibilityTests {
    @Test func characterRangesUseTheUTF16CoordinatesExpectedByAppKit() {
        let snapshot = TerminalTextSnapshot(value: "a😀b")

        #expect(snapshot.characterRange == NSRange(location: 0, length: 4))
        #expect(snapshot.substring(in: NSRange(location: 1, length: 2)) == "😀")
        #expect(snapshot.substring(in: NSRange(location: 3, length: 2)) == nil)
    }

    @Test func lineNavigationClampsIndicesToTheAvailableText() {
        let snapshot = TerminalTextSnapshot(value: "first\nsecond\nthird")

        #expect(snapshot.line(at: 0) == 0)
        #expect(snapshot.line(at: 7) == 1)
        #expect(snapshot.line(at: 10_000) == 2)
        #expect(snapshot.line(at: -10) == 0)
    }
}
