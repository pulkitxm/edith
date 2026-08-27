import Foundation

public struct EmojiUsage: Codable, Hashable, Sendable {
    public let character: String
    public var count: Int
    public var lastUsedAt: Date

    public init(character: String, count: Int, lastUsedAt: Date) {
        self.character = character
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

public struct EmojiUsageLedger: Codable, Sendable {
    public static let halfLifeDays: Double = 21
    public static let capacity = 200

    public private(set) var entries: [EmojiUsage]

    public init(entries: [EmojiUsage] = []) {
        self.entries = entries
    }

    public static func score(_ usage: EmojiUsage, now: Date) -> Double {
        let ageDays = max(now.timeIntervalSince(usage.lastUsedAt), 0) / 86_400
        return Double(usage.count) * pow(0.5, ageDays / halfLifeDays)
    }

    public func ranked(now: Date, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let scored: [(character: String, score: Double, lastUsedAt: Date)] = entries.map {
            ($0.character, Self.score($0, now: now), $0.lastUsedAt)
        }
        let ordered = scored.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            if first.lastUsedAt != second.lastUsedAt { return first.lastUsedAt > second.lastUsedAt }
            return first.character < second.character
        }
        return ordered.prefix(limit).map(\.character)
    }

    public mutating func record(_ character: String, at moment: Date) {
        if let index = entries.firstIndex(where: { $0.character == character }) {
            entries[index].count += 1
            entries[index].lastUsedAt = moment
        } else {
            entries.append(EmojiUsage(character: character, count: 1, lastUsedAt: moment))
        }
        guard entries.count > Self.capacity else { return }
        var survivors = Set(ranked(now: moment, limit: Self.capacity - 1))
        survivors.insert(character)
        entries.removeAll { !survivors.contains($0.character) }
    }

    public mutating func forget(_ character: String) {
        entries.removeAll { $0.character == character }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public static func load(from store: UserDefaults, key: String) -> EmojiUsageLedger {
        guard let data = store.data(forKey: key),
            let decoded = try? JSONDecoder().decode(EmojiUsageLedger.self, from: data)
        else { return EmojiUsageLedger() }
        return decoded
    }

    public func save(to store: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(data, forKey: key)
    }
}
