import AppKit
import Testing
@testable import Edith

@MainActor @Suite(.serialized) struct VideoPlaybackKeysTests {
    @Test func spaceBelongsToTheEditorOutsideTextFields() throws {
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200))
        defer { window.orderOut(nil) }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView = content
        window.orderBack(nil)
        let keys = VideoPlaybackKeyView()
        content.addSubview(keys)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 22))
        content.addSubview(field)
        func press(
            _ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []
        ) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        #expect(VideoPlaybackKeyView.claims(try press(49, " ")))
        #expect(VideoPlaybackKeyView.claims(try press(49, " ", .shift)))
        #expect(!VideoPlaybackKeyView.claims(try press(49, " ", .command)))
        #expect(!VideoPlaybackKeyView.claims(try press(0, "a")))
        window.makeFirstResponder(field)
        #expect(!VideoPlaybackKeyView.claims(try press(49, " ")))
        window.makeFirstResponder(nil)
        #expect(VideoPlaybackKeyView.claims(try press(49, " ")))
        keys.removeFromSuperview()
        #expect(!VideoPlaybackKeyView.claims(try press(49, " ")))
    }
}
