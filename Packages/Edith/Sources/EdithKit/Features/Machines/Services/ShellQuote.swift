import Foundation

public enum ShellQuote {
    public static func quote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ Self.safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    private static let safeCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/=:@%,")
}
