import Carbon.HIToolbox
import Foundation

public enum HotKeyGlyph {
    public static let namedKeys: [Int: String] = [
        kVK_Space: "\u{2423}",
        kVK_Return: "\u{21A9}",
        kVK_ANSI_KeypadEnter: "\u{2324}",
        kVK_Tab: "\u{21E5}",
        kVK_Delete: "\u{232B}",
        kVK_ForwardDelete: "\u{2326}",
        kVK_Escape: "\u{238B}",
        kVK_LeftArrow: "\u{2190}",
        kVK_RightArrow: "\u{2192}",
        kVK_UpArrow: "\u{2191}",
        kVK_DownArrow: "\u{2193}",
        kVK_Home: "\u{2196}",
        kVK_End: "\u{2198}",
        kVK_PageUp: "\u{21DE}",
        kVK_PageDown: "\u{21DF}",
    ]

    public static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12",
    ]

    public static func key(forKeyCode code: Int, characters: String?) -> String {
        if let named = namedKeys[code] { return named }
        if let function = functionKeys[code] { return function }
        let printable = (characters ?? "").filter {
            !$0.isWhitespace
                && !$0.unicodeScalars.contains { scalar in
                    CharacterSet.controlCharacters.contains(scalar) || scalar.value >= 0xF700
                }
        }
        guard !printable.isEmpty else { return "#\(code)" }
        return printable.uppercased()
    }

    public static func label(modifiers: String, keyCode: Int, characters: String?) -> String {
        modifiers + key(forKeyCode: keyCode, characters: characters)
    }
}
