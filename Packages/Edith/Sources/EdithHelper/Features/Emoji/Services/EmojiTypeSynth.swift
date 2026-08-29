import AppKit
import ApplicationServices
import Foundation

enum EmojiTypeSynth {
    static func type(_ character: String) -> Bool {
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            NSSound.beep()
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        var units = Array(character.utf16)
        guard !units.isEmpty else { return false }
        for keyDown in [true, false] {
            guard
                let event = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            else { return false }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }
}
