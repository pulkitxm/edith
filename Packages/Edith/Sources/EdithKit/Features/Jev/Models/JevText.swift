import Foundation

public enum JevText {
    public static let redaction = "[redacted]"
    public static let secretLength = 20

    public static func compact(_ text: String, limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map { redacted(String($0)) }
        return String(words.joined(separator: " ").prefix(max(0, limit)))
    }

    static func redacted(_ word: String) -> String {
        guard word.count >= secretLength, !word.contains("/"), word.contains(where: \.isLetter),
            word.contains(where: \.isNumber)
        else { return word }
        return redaction
    }
}
