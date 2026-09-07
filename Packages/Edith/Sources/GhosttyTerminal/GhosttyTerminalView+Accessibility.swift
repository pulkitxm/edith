import AppKit
import GhosttyKit

struct TerminalTextSnapshot: Equatable {
    let value: String

    var characterRange: NSRange {
        NSRange(location: 0, length: (value as NSString).length)
    }

    func line(at index: Int) -> Int {
        let text = value as NSString
        let location = min(max(0, index), text.length)
        let prefix = text.substring(to: location)
        return prefix.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    func substring(in range: NSRange) -> String? {
        let text = value as NSString
        guard range.location <= text.length, range.length <= text.length - range.location else {
            return nil
        }
        return text.substring(with: range)
    }
}

extension GhosttyTerminalView {
    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityHelp() -> String? { "Terminal content area" }

    public override func accessibilityValue() -> Any? { accessibilitySnapshot().value }

    public override func accessibilitySelectedTextRange() -> NSRange {
        guard let surface else { return NSRange(location: 0, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return NSRange(location: 0, length: 0)
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public override func accessibilitySelectedText() -> String? { selectedText() }

    public override func accessibilityNumberOfCharacters() -> Int {
        accessibilitySnapshot().characterRange.length
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        accessibilitySnapshot().characterRange
    }

    public override func accessibilityLine(for index: Int) -> Int {
        accessibilitySnapshot().line(at: index)
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        accessibilitySnapshot().substring(in: range)
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let value = accessibilityString(for: range) else { return nil }
        return NSAttributedString(
            string: value,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)])
    }

    private func accessibilitySnapshot() -> TerminalTextSnapshot {
        guard let surface else { return TerminalTextSnapshot(value: "") }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return TerminalTextSnapshot(value: "")
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else {
            return TerminalTextSnapshot(value: "")
        }
        return TerminalTextSnapshot(
            value: String(
                decoding: UnsafeRawBufferPointer(start: raw, count: Int(text.text_len)),
                as: UTF8.self))
    }
}
