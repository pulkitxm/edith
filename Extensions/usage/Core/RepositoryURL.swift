import Foundation

public enum RepositoryURL {
    public static func normalized(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix(".git") { normalized.removeLast(4) }
        return normalized
    }
}
