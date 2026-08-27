import AppKit
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyInputTests {
    @Test func appKitFunctionKeyTextIsNotSentToTheTerminal() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 1,
                windowNumber: 0, context: nil, characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        #expect(GhosttyTerminalView.inputText(for: event) == nil)
    }

    @Test func printableTextStillPassesThrough() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, characters: "x",
                charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(GhosttyTerminalView.inputText(for: event) == "x")
    }
}
