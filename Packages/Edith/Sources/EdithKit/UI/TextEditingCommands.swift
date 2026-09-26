import AppKit
import SwiftUI

@MainActor
public enum TextEditingCommands {
    private static var monitor: Any?
    private static var handledStamp: (TimeInterval, UInt16, Int)?

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    public static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let selector = selector(for: event),
            let target = editingTarget(in: event.window),
            allows(selector, editable: target.editable),
            !(target.singleLine && movesDocument(selector))
        else { return false }
        let stamp = (event.timestamp, event.keyCode, event.window?.windowNumber ?? -1)
        if handledStamp?.0 == stamp.0, handledStamp?.1 == stamp.1, handledStamp?.2 == stamp.2 {
            return true
        }
        guard NSApp.sendAction(selector, to: target.responder, from: event) else { return false }
        handledStamp = stamp
        return true
    }

    public nonisolated static func selector(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> Selector? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
            return nil
        }
        let shifted = flags.contains(.shift)
        if let character = letter(characters: characters, keyCode: keyCode) {
            return letterSelector(character, shifted: shifted)
        }
        switch (keyCode, characters) {
        case (Key.delete, _), (_, "\u{7F}"), (_, "\u{8}"):
            return shifted ? nil : #selector(NSResponder.deleteToBeginningOfLine(_:))
        case (Key.forwardDelete, _), (_, "\u{F728}"):
            return shifted ? nil : #selector(NSResponder.deleteToEndOfLine(_:))
        case (Key.left, _):
            return shifted
                ? #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:))
                : #selector(NSResponder.moveToLeftEndOfLine(_:))
        case (Key.right, _):
            return shifted
                ? #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:))
                : #selector(NSResponder.moveToRightEndOfLine(_:))
        case (Key.up, _):
            return shifted
                ? #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:))
                : #selector(NSResponder.moveToBeginningOfDocument(_:))
        case (Key.down, _):
            return shifted
                ? #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:))
                : #selector(NSResponder.moveToEndOfDocument(_:))
        default:
            return nil
        }
    }

    public nonisolated static func selector(for event: NSEvent) -> Selector? {
        selector(
            characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
            modifiers: event.modifierFlags)
    }

    private nonisolated static func letter(characters: String?, keyCode: UInt16) -> Character? {
        if let characters, characters.count == 1, let character = characters.lowercased().first,
            character.isASCII, character.isLetter
        {
            return character
        }
        guard characters?.isEmpty != false else { return nil }
        switch keyCode {
        case Key.a: return "a"
        case Key.z: return "z"
        case Key.x: return "x"
        case Key.c: return "c"
        case Key.v: return "v"
        default: return nil
        }
    }

    private nonisolated static func letterSelector(_ character: Character, shifted: Bool)
        -> Selector?
    {
        switch character {
        case "a": shifted ? nil : #selector(NSText.selectAll(_:))
        case "c": shifted ? nil : #selector(NSText.copy(_:))
        case "x": shifted ? nil : #selector(NSText.cut(_:))
        case "v": shifted ? nil : #selector(NSText.paste(_:))
        case "z": shifted ? Selector(("redo:")) : Selector(("undo:"))
        default: nil
        }
    }

    private static func allows(_ selector: Selector, editable: Bool) -> Bool {
        if editable { return true }
        return selector == #selector(NSText.selectAll(_:)) || selector == #selector(NSText.copy(_:))
    }

    private static func movesDocument(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.moveToBeginningOfDocument(_:))
            || selector == #selector(NSResponder.moveToEndOfDocument(_:))
            || selector == #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:))
            || selector == #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:))
    }

    private static func editingTarget(in window: NSWindow?) -> EditingTarget? {
        guard let responder = window?.firstResponder else { return nil }
        if let text = responder as? NSTextView {
            guard text.isEditable || text.isSelectable else { return nil }
            return EditingTarget(
                responder: text, editable: text.isEditable, singleLine: text.isFieldEditor)
        }
        if let field = responder as? NSTextField, field.isEditable || field.isSelectable {
            return EditingTarget(
                responder: field.currentEditor() ?? field, editable: field.isEditable,
                singleLine: true)
        }
        return nil
    }

    private struct EditingTarget {
        let responder: NSResponder
        let editable: Bool
        let singleLine: Bool
    }

    private nonisolated enum Key {
        static let a: UInt16 = 0
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }
}

extension View {
    public func textEditingCommands() -> some View {
        onAppear { TextEditingCommands.install() }
    }
}
