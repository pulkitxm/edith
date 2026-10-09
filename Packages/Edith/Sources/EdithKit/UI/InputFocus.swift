import AppKit

public protocol DirectKeyboardInputResponder: AnyObject {}

@MainActor
public enum InputFocus {
    private static var monitor: Any?

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard let window = event.window else { return event }
            if event.type == .keyDown,
                isSearchShortcut(
                    characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
                !(window.firstResponder is DirectKeyboardInputResponder),
                (window.firstResponder as? NSTextView).map({ $0.isFieldEditor }) != false,
                TypeAhead.shared.focusField(in: window, selectAll: true)
            {
                return nil
            }
            guard let editor = editingTextView(in: window) else {
                if event.type == .keyDown,
                    shouldStartTypeAhead(
                        characters: event.characters, modifiers: event.modifierFlags,
                        responder: window.firstResponder)
                {
                    TypeAhead.shared.focusField(in: window, typeAheadOnly: true)
                }
                return event
            }
            if event.type == .leftMouseDown,
                !clickLandsInside(editor: editor, window: window, location: event.locationInWindow)
            {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    public static func resignEditing() {
        guard let window = NSApp.keyWindow, editingTextView(in: window) != nil else { return }
        window.makeFirstResponder(nil)
    }

    public static func isTypeAheadKey(characters: String?, modifiers: NSEvent.ModifierFlags)
        -> Bool
    {
        guard modifiers.intersection([.command, .option, .control, .function]).isEmpty,
            let letter = characters?.first, characters?.count == 1
        else { return false }
        return letter.isASCII && letter.isLetter
    }

    static func isSearchShortcut(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .option, .control, .shift]) == .command
            && characters?.lowercased() == "f"
    }

    static func shouldStartTypeAhead(
        characters: String?, modifiers: NSEvent.ModifierFlags, responder: NSResponder?
    ) -> Bool {
        !(responder is DirectKeyboardInputResponder)
            && isTypeAheadKey(characters: characters, modifiers: modifiers)
    }

    private static func editingTextView(in window: NSWindow) -> NSTextView? {
        guard let text = window.firstResponder as? NSTextView, text.isFieldEditor || text.isEditable
        else { return nil }
        return text
    }

    private static func clickLandsInside(
        editor: NSTextView, window: NSWindow, location: NSPoint
    ) -> Bool {
        let control = (editor.delegate as? NSView) ?? editor
        guard let hit = window.contentView?.hitTest(location) else { return false }
        return hit.isDescendant(of: control)
    }
}

@MainActor
public final class TypeAhead {
    public static let shared = TypeAhead()

    private struct Entry {
        weak var anchor: NSView?
        let typeAhead: Bool
    }

    private var entries: [Entry] = []

    public func register(anchor: NSView, typeAhead: Bool = true) {
        entries.removeAll { $0.anchor == nil || $0.anchor === anchor }
        entries.append(Entry(anchor: anchor, typeAhead: typeAhead))
    }

    public func unregister(anchor: NSView) {
        entries.removeAll { $0.anchor == nil || $0.anchor === anchor }
    }

    @discardableResult
    func focusField(in window: NSWindow, typeAheadOnly: Bool = false, selectAll: Bool = false)
        -> Bool
    {
        let inputTrace = PerformanceTrace.begin(.input, "main.typeAhead")
        defer { PerformanceTrace.end(inputTrace) }
        entries.removeAll { $0.anchor == nil }
        for entry in entries.reversed() where !typeAheadOnly || entry.typeAhead {
            guard visible(entry.anchor, in: window), let anchor = entry.anchor,
                let field = editableField(under: anchor), window.makeFirstResponder(field)
            else { continue }
            if let editor = field.currentEditor() {
                let length = (editor.string as NSString).length
                editor.selectedRange =
                    selectAll
                    ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
            }
            return true
        }
        return false
    }

    private func visible(_ anchor: NSView?, in window: NSWindow) -> Bool {
        guard let anchor, anchor.window === window else { return false }
        return !anchor.isHiddenOrHasHiddenAncestor && !anchor.visibleRect.isEmpty
    }

    private func editableField(under anchor: NSView) -> NSTextField? {
        guard let root = anchor.window?.contentView else { return nil }
        return firstEditableField(in: root, overlapping: anchor.convert(anchor.bounds, to: nil))
    }

    private func firstEditableField(in view: NSView, overlapping rect: NSRect) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable, field.isEnabled,
                !field.isHiddenOrHasHiddenAncestor,
                field.convert(field.bounds, to: nil).intersects(rect)
            {
                return field
            }
            if let found = firstEditableField(in: subview, overlapping: rect) { return found }
        }
        return nil
    }
}
