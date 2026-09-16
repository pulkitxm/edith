import Foundation

public struct BifrostUsage: Codable, Hashable, Sendable {
    public let target: String
    public var count: Int
    public var lastUsedAt: Date

    public init(target: String, count: Int, lastUsedAt: Date) {
        self.target = target
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

public struct BifrostUsageLedger: Codable, Sendable, Equatable {
    public static let halfLifeDays: Double = 14
    public static let capacity = 300
    public static let scoreCeiling = 240
    public static let queryCeiling = 420
    public static let queryPrefix = "q:"
    public static let querySeparator: Character = "\u{1}"

    public private(set) var entries: [BifrostUsage]

    public init(entries: [BifrostUsage] = []) {
        self.entries = entries
    }

    public static func score(_ usage: BifrostUsage, now: Date) -> Double {
        let ageDays = max(now.timeIntervalSince(usage.lastUsedAt), 0) / 86_400
        return Double(usage.count) * pow(0.5, ageDays / halfLifeDays)
    }

    public func boost(for target: String, now: Date) -> Int {
        guard let usage = entries.first(where: { $0.target == target }) else { return 0 }
        let decayed = Self.score(usage, now: now)
        guard decayed > 0 else { return 0 }
        return min(Int((log2(decayed + 1) * 60).rounded()), Self.scoreCeiling)
    }

    public static func queryKey(query: String, target: String) -> String? {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return nil }
        return queryPrefix + normalized + String(querySeparator) + target
    }

    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func lesson(decayed: Double, exact: Bool) -> Int {
        let weight = exact ? 300.0 : 150.0
        let repeats = exact ? 60.0 : 30.0
        let scaled = weight * min(decayed, 1) + repeats * log2(decayed + 1)
        return min(Int(scaled.rounded()), queryCeiling)
    }

    public func queryBoost(for target: String, query: String, now: Date) -> Int {
        let typed = Self.normalize(query)
        guard !typed.isEmpty else { return 0 }
        var best = 0
        for entry in entries {
            guard entry.target.hasPrefix(Self.queryPrefix) else { continue }
            let body = entry.target.dropFirst(Self.queryPrefix.count)
            guard let split = body.firstIndex(of: Self.querySeparator) else { continue }
            let learned = String(body[body.startIndex..<split])
            guard String(body[body.index(after: split)...]) == target else { continue }
            guard learned.hasPrefix(typed) else { continue }
            let decayed = Self.score(entry, now: now)
            guard decayed > 0 else { continue }
            best = max(best, Self.lesson(decayed: decayed, exact: learned.count == typed.count))
        }
        return best
    }

    public mutating func record(_ target: String, query: String, at moment: Date) {
        record(target, at: moment)
        guard let key = Self.queryKey(query: query, target: target) else { return }
        record(key, at: moment)
    }

    public func ranked(now: Date, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let scored: [(target: String, score: Double, lastUsedAt: Date)] =
            entries
            .filter { !$0.target.hasPrefix(Self.queryPrefix) }
            .map { ($0.target, Self.score($0, now: now), $0.lastUsedAt) }
        let ordered = scored.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            if first.lastUsedAt != second.lastUsedAt { return first.lastUsedAt > second.lastUsedAt }
            return first.target < second.target
        }
        return ordered.prefix(limit).map(\.target)
    }

    public mutating func record(_ target: String, at moment: Date) {
        if let index = entries.firstIndex(where: { $0.target == target }) {
            entries[index].count += 1
            entries[index].lastUsedAt = moment
        } else {
            entries.append(BifrostUsage(target: target, count: 1, lastUsedAt: moment))
        }
        guard entries.count > Self.capacity else { return }
        var survivors = Set(ranked(now: moment, limit: Self.capacity - 1))
        survivors.insert(target)
        entries.removeAll { !survivors.contains($0.target) }
    }

    public mutating func forget(_ target: String) {
        entries.removeAll { $0.target == target }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public static func load(from store: UserDefaults, key: String) -> BifrostUsageLedger {
        guard let data = store.data(forKey: key),
            let decoded = try? JSONDecoder().decode(BifrostUsageLedger.self, from: data)
        else { return BifrostUsageLedger() }
        return decoded
    }

    public func save(to store: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(data, forKey: key)
    }
}
