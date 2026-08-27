import Foundation

public enum EmojiSearch {
    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ":", with: "")
    }

    public static func score(_ emoji: Emoji, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        if emoji.name == query { return 0 }
        if emoji.name.hasPrefix(query) { return 1 }
        if words(of: emoji.name).contains(where: { $0.hasPrefix(query) }) { return 2 }
        if emoji.terms.contains(query) { return 3 }
        if emoji.terms.contains(where: { $0.hasPrefix(query) }) { return 4 }
        if emoji.name.contains(query) { return 5 }
        if emoji.terms.contains(where: { $0.contains(query) }) { return 6 }
        return nil
    }

    public static func results(in emoji: [Emoji], query: String, limit: Int = .max) -> [Emoji] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return Array(emoji.prefix(limit)) }
        return
            emoji
            .enumerated()
            .compactMap { index, entry -> (Emoji, Int, Int)? in
                guard let rank = score(entry, query: normalized) else { return nil }
                return (entry, rank, index)
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .prefix(limit)
            .map(\.0)
    }

    private static func words(of name: String) -> [Substring] {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}
