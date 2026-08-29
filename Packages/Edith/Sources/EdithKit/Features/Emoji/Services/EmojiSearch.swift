import Foundation

public struct EmojiSearchIndex: Sendable {
    private struct Entry: Sendable {
        let emoji: Emoji
        let name: String
        let words: [Substring]
        let terms: [String]
    }

    private let entries: [Entry]

    fileprivate struct Match: Sendable {
        let catalogOrderIndices: [Int]
        let rankedEmoji: [Emoji]
    }

    public init(_ emoji: [Emoji]) {
        entries = emoji.map { emoji in
            let name = EmojiSearch.normalize(emoji.name)
            return Entry(
                emoji: emoji, name: name,
                words: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }),
                terms: emoji.terms.map(EmojiSearch.normalize))
        }
    }

    public func results(query: String, limit: Int = .max) -> [Emoji] {
        let normalized = EmojiSearch.normalize(query)
        guard !normalized.isEmpty else {
            return Array(entries.lazy.map(\.emoji).prefix(limit))
        }
        guard let match = match(query: normalized) else { return [] }
        return Array(match.rankedEmoji.prefix(limit))
    }

    fileprivate func match(query: String, candidates: [Int]? = nil) -> Match? {
        var catalogOrderIndices: [Int] = []
        var rankedIndices = Array(repeating: [Int](), count: 7)
        catalogOrderIndices.reserveCapacity(candidates?.count ?? entries.count)

        func include(_ index: Int) {
            guard let rank = score(entries[index], query: query) else { return }
            catalogOrderIndices.append(index)
            rankedIndices[rank].append(index)
        }

        if let candidates {
            for (offset, index) in candidates.enumerated() {
                if offset.isMultiple(of: 64), Task.isCancelled { return nil }
                include(index)
            }
        } else {
            for index in entries.indices {
                if index.isMultiple(of: 64), Task.isCancelled { return nil }
                include(index)
            }
        }

        var rankedEmoji: [Emoji] = []
        rankedEmoji.reserveCapacity(catalogOrderIndices.count)
        for bucket in rankedIndices {
            for index in bucket { rankedEmoji.append(entries[index].emoji) }
        }
        return Match(catalogOrderIndices: catalogOrderIndices, rankedEmoji: rankedEmoji)
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

public actor EmojiSearchService {
    private let indexTask: Task<EmojiSearchIndex, Never>
    private var cachedQuery = ""
    private var cachedCatalogOrderIndices: [Int] = []
    private var cachedResults: [Emoji] = []

    public init(_ emoji: [Emoji]) {
        indexTask = Task.detached(priority: .userInitiated) { EmojiSearchIndex(emoji) }
    }

    deinit {
        indexTask.cancel()
    }

    public func results(query: String, limit: Int = .max) async -> [Emoji] {
        let normalized = EmojiSearch.normalize(query)
        let index = await indexTask.value
        guard !normalized.isEmpty else {
            cachedQuery = ""
            cachedCatalogOrderIndices = []
            cachedResults = []
            return index.results(query: normalized, limit: limit)
        }
        if normalized == cachedQuery {
            return Array(cachedResults.prefix(limit))
        }
        let candidates =
            !cachedQuery.isEmpty && normalized.hasPrefix(cachedQuery)
            ? cachedCatalogOrderIndices : nil
        guard let match = index.match(query: normalized, candidates: candidates) else { return [] }
        cachedQuery = normalized
        cachedCatalogOrderIndices = match.catalogOrderIndices
        cachedResults = match.rankedEmoji
        return Array(cachedResults.prefix(limit))
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
