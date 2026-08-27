import CoreGraphics
import Foundation

enum EmojiTypeSynth {
    static func type(_ character: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var units = Array(character.utf16)
        guard !units.isEmpty else { return }
        for keyDown in [true, false] {
            guard
                let event = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
