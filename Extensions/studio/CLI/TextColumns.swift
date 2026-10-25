import Foundation

public enum TextColumns {
    public static func pad(_ text: String, to width: Int) -> String {
        let missing = width - text.count
        guard missing > 0 else { return text }
        return text + String(repeating: " ", count: missing)
    }

    public static func leftPad(_ text: String, to width: Int) -> String {
        let missing = width - text.count
        guard missing > 0 else { return text }
        return String(repeating: " ", count: missing) + text
    }
}
