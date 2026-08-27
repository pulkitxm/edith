import AppKit
import GhosttyKit

extension GhosttyTerminalView: NSTextInputClient {
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        if let value = string as? NSAttributedString {
            markedText.setAttributedString(value)
        } else if let value = string as? String {
            markedText.mutableString.setString(value)
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard range.length > 0, let text = selectedText() else { return nil }
        actualRange?.pointee = selectedRange()
        return NSAttributedString(string: text)
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(
        forCharacterRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSRect {
        guard let surface else {
            return window?.convertToScreen(convert(bounds, to: nil)) ?? bounds
        }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let local = NSRect(
            x: x, y: bounds.height - y, width: max(1, width), height: max(18, height))
        let windowRect = convert(local, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let value: String
        if let attributed = string as? NSAttributedString {
            value = attributed.string
        } else if let plain = string as? String {
            value = plain
        } else if let plain = string as? NSString {
            value = plain as String
        } else {
            return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(value)
        } else {
            _ = insertText(value)
        }
    }

    public override func doCommand(by selector: Selector) {}

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let value = markedText.string
            value.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(value.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
