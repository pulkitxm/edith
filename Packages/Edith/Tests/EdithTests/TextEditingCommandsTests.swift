import AppKit
import Testing

@testable import EdithKit

@MainActor
@Suite(.serialized) struct TextEditingCommandsTests {
    @Test func lettersMapToTheStandardEditActions() {
        #expect(mapped("a") == #selector(NSText.selectAll(_:)))
        #expect(mapped("c") == #selector(NSText.copy(_:)))
        #expect(mapped("x") == #selector(NSText.cut(_:)))
        #expect(mapped("v") == #selector(NSText.paste(_:)))
        #expect(mapped("z") == Selector(("undo:")))
        #expect(mapped("Z", [.command, .shift]) == Selector(("redo:")))
        #expect(mapped("A") == #selector(NSText.selectAll(_:)))
    }

    @Test func commandBackspaceAndForwardDeleteEditTheLine() {
        #expect(mapped(keyCode: 51) == #selector(NSResponder.deleteToBeginningOfLine(_:)))
        #expect(mapped("\u{7F}") == #selector(NSResponder.deleteToBeginningOfLine(_:)))
        #expect(mapped(keyCode: 117) == #selector(NSResponder.deleteToEndOfLine(_:)))
        #expect(mapped("\u{F728}") == #selector(NSResponder.deleteToEndOfLine(_:)))
        #expect(mapped(keyCode: 51, [.command, .shift]) == nil)
    }

    @Test func commandArrowsMoveWithinTheField() {
        #expect(mapped(keyCode: 123) == #selector(NSResponder.moveToLeftEndOfLine(_:)))
        #expect(
            mapped(keyCode: 124, [.command, .shift])
                == #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)))
        #expect(mapped(keyCode: 126) == #selector(NSResponder.moveToBeginningOfDocument(_:)))
        #expect(
            mapped(keyCode: 125, [.command, .shift])
                == #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)))
    }

    @Test func otherChordsStayWithTheSurroundingFeature() {
        #expect(mapped("a", [.command, .option]) == nil)
        #expect(mapped("a", [.command, .shift]) == nil)
        #expect(mapped("p") == nil)
        #expect(mapped("1") == nil)
        #expect(mapped("a", []) == nil)
        #expect(mapped(keyCode: 51, [.command, .option]) == nil)
        #expect(mapped(keyCode: 126, [.command, .option]) == nil)
        #expect(mapped(keyCode: 123, .option) == nil)
    }

    @Test func aFocusedFieldSelectsAllAndDeletesToTheStart() throws {
        let window = host()
        defer { window.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.stringValue = "clipboard"
        window.contentView = field
        let editor = try editor(for: field, in: window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(try handle("a", keyCode: 0, window: window, timestamp: 1))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 9))

        editor.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(try handle("\u{7F}", keyCode: 51, window: window, timestamp: 2))
        #expect(editor.string == "board")

        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(try handle("\u{F702}", keyCode: 123, window: window, timestamp: 3))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))

        #expect(try !handle("\u{F700}", keyCode: 126, window: window, timestamp: 4))
        #expect(editor.selectedRange().location == 0)
        #expect(
            try !handle(
                "\u{7F}", keyCode: 51, modifiers: [.command, .option], window: window, timestamp: 5)
        )
        #expect(editor.string == "board")
    }

    @Test func commandAThenCommandBackspaceClearsTheField() throws {
        let window = host()
        defer { window.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.stringValue = "clipboard"
        window.contentView = field
        let editor = try editor(for: field, in: window)

        #expect(try handle("a", keyCode: 0, window: window, timestamp: 11))
        #expect(try handle("\u{7F}", keyCode: 51, window: window, timestamp: 12))
        #expect(editor.string.isEmpty)
    }

    @Test func aMultilineEditorJumpsToTheDocumentEnds() throws {
        let window = host()
        defer { window.orderOut(nil) }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        text.string = "one\ntwo"
        text.isEditable = true
        text.isSelectable = true
        window.contentView = text
        window.makeKey()
        #expect(window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))

        #expect(try handle("\u{F700}", keyCode: 126, window: window, timestamp: 21))
        #expect(text.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func readOnlyTextCanSelectAndCopyButNotDelete() throws {
        let window = host()
        defer { window.orderOut(nil) }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        text.string = "logs"
        text.isEditable = false
        text.isSelectable = true
        window.contentView = text
        window.makeKey()
        #expect(window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(try handle("a", keyCode: 0, window: window, timestamp: 31))
        #expect(text.selectedRange().length == 4)
        #expect(try !handle("\u{7F}", keyCode: 51, window: window, timestamp: 32))
        #expect(text.string == "logs")
    }

    @Test func theInstalledMonitorSelectsAllInTheFocusedField() throws {
        TextEditingCommands.install()
        let window = host()
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
        }
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.stringValue = "clipboard"
        window.contentView = field
        let editor = try editor(for: field, in: window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 51,
                windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        NSApp.sendEvent(event)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 9))
    }

    @Test func keysOutsideATextFieldAreLeftAlone() throws {
        let window = host()
        defer { window.orderOut(nil) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        window.contentView = view
        window.makeKey()
        #expect(window.makeFirstResponder(view))
        #expect(try !handle("a", keyCode: 0, window: window, timestamp: 41))
    }

    private func host() -> OffscreenTestWindow {
        _ = TestWindowHost.application
        return TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120))
    }

    private func editor(for field: NSTextField, in window: NSWindow) throws -> NSTextView {
        window.makeKey()
        #expect(window.makeFirstResponder(field))
        return try #require(window.firstResponder as? NSTextView)
    }

    private func handle(
        _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = .command,
        window: NSWindow, timestamp: TimeInterval
    ) throws -> Bool {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        return TextEditingCommands.handle(event)
    }

    private func mapped(
        _ characters: String? = nil, keyCode: UInt16 = 0,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> Selector? {
        TextEditingCommands.selector(
            characters: characters, keyCode: keyCode, modifiers: modifiers)
    }
}
