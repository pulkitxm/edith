import AppKit
import CoreGraphics

public enum KeystrokeEventLabelReader {
    public static func labels(from event: CGEvent) -> [String]? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
        return KeystrokeLabelResolver.labels(
            keyCode: keyCode, characters: characters,
            unmodifiedCharacters: unmodifiedCharacters(keyCode: keyCode),
            modifiers: modifiers(from: event.flags))
    }

    public static func modifiers(from flags: CGEventFlags) -> KeystrokeModifiers {
        var modifiers: KeystrokeModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }

    private static func unmodifiedCharacters(keyCode: UInt16) -> String? {
        guard
            let event = CGEvent(
                keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
        else { return nil }
        event.flags = []
        return NSEvent(cgEvent: event)?.charactersIgnoringModifiers
    }
}
