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

public struct CodeStatsCommitFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let formatting = CodeStatsCommitFlags(rawValue: 1)
    public static let agentAssisted = CodeStatsCommitFlags(rawValue: 2)
    public static let coAuthored = CodeStatsCommitFlags(rawValue: 4)
    public static let bulk = CodeStatsCommitFlags(rawValue: 8)

    public static let named: [(CodeStatsCommitFlags, String)] = [
        (.bulk, "bulk"), (.formatting, "formatting"), (.agentAssisted, "agentAssisted"),
        (.coAuthored, "coAuthored"),
    ]

    public var names: [String] { Self.named.filter { contains($0.0) }.map(\.1) }
}

public struct CodeStatsChange: Codable, Equatable, Hashable, Sendable {
    public var language: String
    public var category: CodeStatsCategory
    public var counts: CodeStatsLanguageCounts
    public var raw: CodeStatsLanguageCounts

    public init(
        language: String, category: CodeStatsCategory, counts: CodeStatsLanguageCounts,
        raw: CodeStatsLanguageCounts? = nil
    ) {
        self.language = language
        self.category = category
        self.counts = counts
        self.raw = raw ?? counts
    }
}

public struct CodeStatsCommit: Codable, Equatable, Hashable, Sendable {
    public var sha: String
    public var day: String
    public var hour: Int
    public var repository: String
    public var timestamp: Int
    public var subject: String
    public var files: Int
    public var fingerprint: String?
    public var flags: CodeStatsCommitFlags
    public var changes: [CodeStatsChange]

    public init(
        sha: String, day: String, hour: Int, repository: String, timestamp: Int = 0,
        subject: String = "", files: Int = 0, fingerprint: String? = nil,
        flags: CodeStatsCommitFlags = [], changes: [CodeStatsChange] = []
    ) {
        self.sha = sha
        self.day = day
        self.hour = hour
        self.repository = repository
        self.timestamp = timestamp
        self.subject = subject
        self.files = files
        self.fingerprint = fingerprint
        self.flags = flags
        self.changes = changes
    }

    public init(
        sha: String, day: String, hour: Int, repository: String,
        languages: [String: CodeStatsLanguageCounts]
    ) {
        self.init(
            sha: sha, day: day, hour: hour, repository: repository,
            changes: languages.sorted { $0.key < $1.key }.map {
                CodeStatsChange(language: $0.key, category: .code, counts: $0.value)
            })
    }

    public var languages: [String: CodeStatsLanguageCounts] {
        changes.reduce(into: [:]) { result, change in
            guard change.category != .generated else { return }
            result[change.language, default: .zero].add(change.counts)
        }
    }

    public var totals: CodeStatsLanguageCounts {
        changes.reduce(into: CodeStatsLanguageCounts()) {
            if $1.category != .generated { $0.add($1.counts) }
        }
    }

    public var rawTotals: CodeStatsLanguageCounts {
        changes.reduce(into: CodeStatsLanguageCounts()) { $0.add($1.raw) }
    }

    public var owner: String {
        repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repository
    }

    public mutating func record(
        language: String, category: CodeStatsCategory, counts: CodeStatsLanguageCounts,
        raw: CodeStatsLanguageCounts
    ) {
        if let index = changes.firstIndex(where: {
            $0.language == language && $0.category == category
        }) {
            changes[index].counts.add(counts)
            changes[index].raw.add(raw)
        } else {
            changes.append(
                CodeStatsChange(language: language, category: category, counts: counts, raw: raw))
        }
    }
}
