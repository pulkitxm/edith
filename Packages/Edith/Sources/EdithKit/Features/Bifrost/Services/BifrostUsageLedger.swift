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

    public func ranked(now: Date, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let scored: [(target: String, score: Double, lastUsedAt: Date)] = entries.map {
            ($0.target, Self.score($0, now: now), $0.lastUsedAt)
        }
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
