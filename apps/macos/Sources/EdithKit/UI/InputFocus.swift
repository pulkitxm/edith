import AppKit

@MainActor
public enum InputFocus {
    private static var monitor: Any?

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard let window = event.window else { return event }
            guard let editor = editingTextView(in: window) else {
                if event.type == .keyDown,
                    isTypeAheadKey(characters: event.characters, modifiers: event.modifierFlags)
                {
                    TypeAhead.shared.focusField(in: window)
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
    }

    private var entries: [Entry] = []

    public func register(anchor: NSView) {
        entries.removeAll { $0.anchor == nil || $0.anchor === anchor }
        entries.append(Entry(anchor: anchor))
    }

    public func unregister(anchor: NSView) {
        entries.removeAll { $0.anchor == nil || $0.anchor === anchor }
    }

    @discardableResult
    func focusField(in window: NSWindow) -> Bool {
        entries.removeAll { $0.anchor == nil }
        guard let anchor = entries.last(where: { visible($0.anchor, in: window) })?.anchor,
            let field = editableField(under: anchor), window.makeFirstResponder(field)
        else { return false }
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        return true
    }

    private func visible(_ anchor: NSView?, in window: NSWindow) -> Bool {
        guard let anchor, anchor.window === window else { return false }
        return !anchor.isHiddenOrHasHiddenAncestor
    }

    private func editableField(under anchor: NSView) -> NSTextField? {
        guard let root = anchor.window?.contentView else { return nil }
        return firstEditableField(in: root, overlapping: anchor.convert(anchor.bounds, to: nil))
    }

    private func firstEditableField(in view: NSView, overlapping rect: NSRect) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable,
                field.convert(field.bounds, to: nil).intersects(rect)
            {
                return field
            }
            if let found = firstEditableField(in: subview, overlapping: rect) { return found }
        }
        return nil
    }
}
