import EdithExtensionSupport
import Foundation

public struct CodeStatsFact: Equatable, Hashable, Sendable {
    public var day: Int
    public var hour: Int
    public var repository: Int
    public var language: Int
    public var category: CodeStatsCategory
    public var flags: CodeStatsCommitFlags
    public var commits: Int
    public var counts: CodeStatsLanguageCounts
    public var raw: Int

    public init(
        day: Int, hour: Int, repository: Int, language: Int, category: CodeStatsCategory,
        flags: CodeStatsCommitFlags, commits: Int, counts: CodeStatsLanguageCounts, raw: Int
    ) {
        self.day = day
        self.hour = hour
        self.repository = repository
        self.language = language
        self.category = category
        self.flags = flags
        self.commits = commits
        self.counts = counts
        self.raw = raw
    }
}

public struct CodeStatsFactCommit: Codable, Equatable, Sendable {
    public var sha: String
    public var repository: String
    public var day: String
    public var subject: String
    public var lines: Int
    public var raw: Int
    public var files: Int
    public var flags: CodeStatsCommitFlags
}

public struct CodeStatsTally: Codable, Equatable, Sendable {
    public var commits: Int
    public var lines: Int

    public init(commits: Int = 0, lines: Int = 0) {
        self.commits = commits
        self.lines = lines
    }

    public mutating func add(commits: Int = 0, lines: Int = 0) {
        self.commits += commits
        self.lines += lines
    }
}

public struct CodeStatsDuplicateRepository: Codable, Equatable, Sendable {
    public var repository: String
    public var original: String
    public var shared: Int
    public var fraction: Double
}

public enum CodeStatsSuggestionReason: String, Codable, Sendable {
    case noreply
    case hostname
    case sameName
    case variant

    public var summary: String {
        switch self {
        case .noreply: "GitHub noreply address for your login"
        case .hostname: "machine hostname email with your name"
        case .sameName: "same name as your profile or identities"
        case .variant: "close variant of your login or name"
        }
    }
}

public struct CodeStatsIdentitySuggestion: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var email: String
    public var commits: Int
    public var value: String
    public var reason: CodeStatsSuggestionReason
    public var score: Int

    public init(
        name: String, email: String, commits: Int, value: String,
        reason: CodeStatsSuggestionReason, score: Int
    ) {
        self.name = name
        self.email = email
        self.commits = commits
        self.value = value
        self.reason = reason
        self.score = score
    }

    public var id: String { value }
}

public struct CodeStatsFilter: Codable, Equatable, Hashable, Sendable {
    public var repositories: Set<String>
    public var owners: Set<String>
    public var languages: Set<String>
    public var categories: Set<CodeStatsCategory>
    public var includeBulk: Bool
    public var includeFormatting: Bool
    public var includeAgentAssisted: Bool
    public var includeCoAuthored: Bool
    public var excludedRepositories: Set<String>

    public static let `default` = CodeStatsFilter()

    public init(
        repositories: Set<String> = [], owners: Set<String> = [], languages: Set<String> = [],
        categories: Set<CodeStatsCategory> = CodeStatsCategory.counted, includeBulk: Bool = false,
        includeFormatting: Bool = false, includeAgentAssisted: Bool = true,
        includeCoAuthored: Bool = true, excludedRepositories: Set<String> = []
    ) {
        self.repositories = repositories
        self.owners = owners
        self.languages = languages
        self.categories = categories
        self.includeBulk = includeBulk
        self.includeFormatting = includeFormatting
        self.includeAgentAssisted = includeAgentAssisted
        self.includeCoAuthored = includeCoAuthored
        self.excludedRepositories = excludedRepositories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            repositories: try container.decodeIfPresent(Set<String>.self, forKey: .repositories)
                ?? [],
            owners: try container.decodeIfPresent(Set<String>.self, forKey: .owners) ?? [],
            languages: try container.decodeIfPresent(Set<String>.self, forKey: .languages) ?? [],
            categories: try container.decodeIfPresent(
                Set<CodeStatsCategory>.self, forKey: .categories) ?? CodeStatsCategory.counted,
            includeBulk: try container.decodeIfPresent(Bool.self, forKey: .includeBulk) ?? false,
            includeFormatting: try container.decodeIfPresent(
                Bool.self, forKey: .includeFormatting) ?? false,
            includeAgentAssisted: try container.decodeIfPresent(
                Bool.self, forKey: .includeAgentAssisted) ?? true,
            includeCoAuthored: try container.decodeIfPresent(
                Bool.self, forKey: .includeCoAuthored) ?? true,
            excludedRepositories: try container.decodeIfPresent(
                Set<String>.self, forKey: .excludedRepositories) ?? [])
    }

    public var excludedLineFlags: CodeStatsCommitFlags {
        var flags: CodeStatsCommitFlags = []
        if !includeBulk { flags.insert(.bulk) }
        if !includeFormatting { flags.insert(.formatting) }
        return flags
    }

    public var excludedCommitFlags: CodeStatsCommitFlags {
        var flags: CodeStatsCommitFlags = []
        if !includeAgentAssisted { flags.insert(.agentAssisted) }
        if !includeCoAuthored { flags.insert(.coAuthored) }
        return flags
    }
}

public struct CodeStatsFactTable: Equatable, Sendable {
    public static let noLanguage = -1

    public var repositories: [String]
    public var languages: [String]
    public var rows: [CodeStatsFact]
    public var bulkThreshold: Int
    public var largest: [CodeStatsFactCommit]
    public var duplicates: CodeStatsTally
    public var integrated: CodeStatsTally
    public var duplicateRepositories: [CodeStatsDuplicateRepository]
    public var suggestions: [CodeStatsIdentitySuggestion]

    public init(
        repositories: [String] = [], languages: [String] = [], rows: [CodeStatsFact] = [],
        bulkThreshold: Int = 0, largest: [CodeStatsFactCommit] = [],
        duplicates: CodeStatsTally = CodeStatsTally(),
        integrated: CodeStatsTally = CodeStatsTally(),
        duplicateRepositories: [CodeStatsDuplicateRepository] = [],
        suggestions: [CodeStatsIdentitySuggestion] = []
    ) {
        self.repositories = repositories
        self.languages = languages
        self.rows = rows
        self.bulkThreshold = bulkThreshold
        self.largest = largest
        self.duplicates = duplicates
        self.integrated = integrated
        self.duplicateRepositories = duplicateRepositories
        self.suggestions = suggestions
    }
}

extension CodeStatsFactTable: Codable {
    private enum CodingKeys: String, CodingKey {
        case repositories, languages, rows, bulkThreshold, largest, duplicates, integrated
        case duplicateRepositories, suggestions
    }

    private struct Columns: Codable {
        var day: [Int] = []
        var hour: [Int] = []
        var repository: [Int] = []
        var language: [Int] = []
        var category: [Int] = []
        var flags: [Int] = []
        var commits: [Int] = []
        var added: [Int] = []
        var updated: [Int] = []
        var deleted: [Int] = []
        var raw: [Int] = []
    }

    private static let categories = CodeStatsCategory.allCases

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try container.decode([String].self, forKey: .repositories)
        languages = try container.decode([String].self, forKey: .languages)
        bulkThreshold = try container.decode(Int.self, forKey: .bulkThreshold)
        largest = try container.decode([CodeStatsFactCommit].self, forKey: .largest)
        duplicates = try container.decode(CodeStatsTally.self, forKey: .duplicates)
        integrated = try container.decode(CodeStatsTally.self, forKey: .integrated)
        duplicateRepositories = try container.decode(
            [CodeStatsDuplicateRepository].self, forKey: .duplicateRepositories)
        suggestions = try container.decode(
            [CodeStatsIdentitySuggestion].self, forKey: .suggestions)
        let columns = try container.decode(Columns.self, forKey: .rows)
        let count = columns.day.count
        let lengths = [
            columns.hour, columns.repository, columns.language, columns.category, columns.flags,
            columns.commits, columns.added, columns.updated, columns.deleted, columns.raw,
        ].map(\.count)
        guard lengths.allSatisfy({ $0 == count }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rows, in: container, debugDescription: "Fact columns differ in length")
        }
        rows = (0..<count).map { index in
            CodeStatsFact(
                day: columns.day[index], hour: columns.hour[index],
                repository: columns.repository[index], language: columns.language[index],
                category: Self.categories.indices.contains(columns.category[index])
                    ? Self.categories[columns.category[index]] : .code,
                flags: CodeStatsCommitFlags(rawValue: columns.flags[index]),
                commits: columns.commits[index],
                counts: CodeStatsLanguageCounts(
                    added: columns.added[index], updated: columns.updated[index],
                    deleted: columns.deleted[index]),
                raw: columns.raw[index])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repositories, forKey: .repositories)
        try container.encode(languages, forKey: .languages)
        try container.encode(bulkThreshold, forKey: .bulkThreshold)
        try container.encode(largest, forKey: .largest)
        try container.encode(duplicates, forKey: .duplicates)
        try container.encode(integrated, forKey: .integrated)
        try container.encode(duplicateRepositories, forKey: .duplicateRepositories)
        try container.encode(suggestions, forKey: .suggestions)
        var columns = Columns()
        for row in rows {
            columns.day.append(row.day)
            columns.hour.append(row.hour)
            columns.repository.append(row.repository)
            columns.language.append(row.language)
            columns.category.append(Self.categories.firstIndex(of: row.category) ?? 0)
            columns.flags.append(row.flags.rawValue)
            columns.commits.append(row.commits)
            columns.added.append(row.counts.added)
            columns.updated.append(row.counts.updated)
            columns.deleted.append(row.counts.deleted)
            columns.raw.append(row.raw)
        }
        try container.encode(columns, forKey: .rows)
    }
}

public enum CodeStatsAuditReason: String, Codable, CaseIterable, Sendable {
    case bulk
    case formatting
    case generated
    case data
    case markup
    case docs
    case whitespace
    case duplicate
    case squashIntegrated
    case agentAssisted
    case coAuthored
    case unmatchedIdentity

    public var title: String {
        switch self {
        case .bulk: "Bulk commits"
        case .formatting: "Formatting commits"
        case .generated: "Generated files"
        case .data: "Data and config"
        case .markup: "Markup and style"
        case .docs: "Docs"
        case .whitespace: "Whitespace-only lines"
        case .duplicate: "Duplicate content"
        case .squashIntegrated: "Squash-merged branches"
        case .agentAssisted: "Agent-assisted"
        case .coAuthored: "Co-authored"
        case .unmatchedIdentity: "Unmatched identities"
        }
    }
}

public struct CodeStatsAuditEntry: Codable, Equatable, Sendable {
    public var reason: CodeStatsAuditReason
    public var counted: Bool
    public var commits: Int?
    public var lines: Int?

    public init(reason: CodeStatsAuditReason, counted: Bool, commits: Int?, lines: Int?) {
        self.reason = reason
        self.counted = counted
        self.commits = commits
        self.lines = lines
    }
}

public struct CodeStatsAudit: Codable, Equatable, Sendable {
    public var filter: CodeStatsFilter
    public var counted: CodeStatsTally
    public var raw: CodeStatsTally
    public var bulkThreshold: Int
    public var entries: [CodeStatsAuditEntry]
    public var duplicateRepositories: [CodeStatsDuplicateRepository]
    public var suggestions: [CodeStatsIdentitySuggestion]

    public func entry(_ reason: CodeStatsAuditReason) -> CodeStatsAuditEntry? {
        entries.first { $0.reason == reason }
    }

    public func matching(_ identity: CodeStatsIdentity) -> CodeStatsAudit {
        var audit = self
        audit.suggestions = CodeStatsIdentitySuggester.filtered(suggestions, identity: identity)
        let unmatched = audit.suggestions.reduce(0) { $0 + $1.commits }
        audit.entries = entries.map { entry in
            var entry = entry
            if entry.reason == .unmatchedIdentity { entry.commits = unmatched }
            return entry
        }
        return audit
    }
}
