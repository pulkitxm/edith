import Foundation

public struct CodeStatsLanguageCounts: Codable, Equatable, Hashable, Sendable {
    public var added: Int
    public var updated: Int
    public var deleted: Int

    public static let zero = CodeStatsLanguageCounts()

    public init(added: Int = 0, updated: Int = 0, deleted: Int = 0) {
        self.added = added
        self.updated = updated
        self.deleted = deleted
    }

    public var authored: Int { added + updated }
    public var net: Int { added - deleted }
    public var isEmpty: Bool { added == 0 && updated == 0 && deleted == 0 }

    public mutating func add(_ other: CodeStatsLanguageCounts) {
        added += other.added
        updated += other.updated
        deleted += other.deleted
    }

    public mutating func addHunk(removed: Int, inserted: Int) {
        updated += min(removed, inserted)
        added += max(inserted - removed, 0)
        deleted += max(removed - inserted, 0)
    }
}

public struct CodeStatsCommit: Codable, Equatable, Hashable, Sendable {
    public var sha: String
    public var day: String
    public var hour: Int
    public var repository: String
    public var languages: [String: CodeStatsLanguageCounts]

    public init(
        sha: String, day: String, hour: Int, repository: String,
        languages: [String: CodeStatsLanguageCounts] = [:]
    ) {
        self.sha = sha
        self.day = day
        self.hour = hour
        self.repository = repository
        self.languages = languages
    }

    public var totals: CodeStatsLanguageCounts {
        languages.values.reduce(into: CodeStatsLanguageCounts()) { $0.add($1) }
    }
}
