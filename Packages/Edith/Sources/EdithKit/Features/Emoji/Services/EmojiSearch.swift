import Foundation

public struct EmojiSearchIndex: Sendable {
    private struct Entry: Sendable {
        let emoji: Emoji
        let name: String
        let words: [Substring]
        let terms: [String]
        let catalogIndex: Int
    }

    private let entries: [Entry]

    public init(_ emoji: [Emoji]) {
        entries = emoji.enumerated().map { index, emoji in
            let name = EmojiSearch.normalize(emoji.name)
            return Entry(
                emoji: emoji, name: name,
                words: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }),
                terms: emoji.terms.map(EmojiSearch.normalize), catalogIndex: index)
        }
    }

    public func results(query: String, limit: Int = .max) -> [Emoji] {
        let normalized = EmojiSearch.normalize(query)
        guard !normalized.isEmpty else {
            return Array(entries.lazy.map(\.emoji).prefix(limit))
        }
        return
            entries
            .compactMap { entry -> (Emoji, Int, Int)? in
                guard let rank = score(entry, query: normalized) else { return nil }
                return (entry.emoji, rank, entry.catalogIndex)
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .prefix(limit)
            .map(\.0)
    }

    private func score(_ entry: Entry, query: String) -> Int? {
        if entry.name == query { return 0 }
        if entry.name.hasPrefix(query) { return 1 }
        if entry.words.contains(where: { $0.hasPrefix(query) }) { return 2 }
        if entry.terms.contains(query) { return 3 }
        if entry.terms.contains(where: { $0.hasPrefix(query) }) { return 4 }
        if entry.name.contains(query) { return 5 }
        if entry.terms.contains(where: { $0.contains(query) }) { return 6 }
        return nil
    }
}

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
        EmojiSearchIndex(emoji).results(query: query, limit: limit)
    }

    private static func words(of name: String) -> [Substring] {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}
