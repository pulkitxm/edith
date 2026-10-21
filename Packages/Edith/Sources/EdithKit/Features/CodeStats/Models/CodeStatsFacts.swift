import Foundation

public enum CodeStatsExclusion: Int, Codable, Sendable {
    case duplicate = 1
    case integrated = 2
}

public struct CodeStatsFactChange: Equatable, Hashable, Sendable {
    public var language: Int
    public var category: CodeStatsCategory
    public var counts: CodeStatsLanguageCounts
    public var raw: Int

    public init(
        language: Int, category: CodeStatsCategory, counts: CodeStatsLanguageCounts, raw: Int
    ) {
        self.language = language
        self.category = category
        self.counts = counts
        self.raw = raw
    }
}

public struct CodeStatsFact: Equatable, Sendable {
    public var sha: String
    public var subject: String
    public var day: Int
    public var hour: Int
    public var repository: Int
    public var flags: CodeStatsCommitFlags
    public var files: Int
    public var lfsFiles: Int
    public var exclusion: CodeStatsExclusion?
    public var changes: [CodeStatsFactChange]

    public init(
        sha: String, subject: String = "", day: Int, hour: Int, repository: Int,
        flags: CodeStatsCommitFlags = [], files: Int = 0, lfsFiles: Int = 0,
        exclusion: CodeStatsExclusion? = nil, changes: [CodeStatsFactChange] = []
    ) {
        self.sha = sha
        self.subject = subject
        self.day = day
        self.hour = hour
        self.repository = repository
        self.flags = flags
        self.files = files
        self.lfsFiles = lfsFiles
        self.exclusion = exclusion
        self.changes = changes
    }

    public var raw: Int { changes.reduce(0) { $0 + $1.raw } }

    public var authored: Int {
        changes.reduce(0) { $0 + ($1.category == .generated ? 0 : $1.counts.authored) }
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
    public var lfsFiles: Int
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
    public var commits: [CodeStatsFact]
    public var bulkThreshold: Int
    public var duplicateRepositories: [CodeStatsDuplicateRepository]
    public var suggestions: [CodeStatsIdentitySuggestion]

    public init(
        repositories: [String] = [], languages: [String] = [], commits: [CodeStatsFact] = [],
        bulkThreshold: Int = 0, duplicateRepositories: [CodeStatsDuplicateRepository] = [],
        suggestions: [CodeStatsIdentitySuggestion] = []
    ) {
        self.repositories = repositories
        self.languages = languages
        self.commits = commits
        self.bulkThreshold = bulkThreshold
        self.duplicateRepositories = duplicateRepositories
        self.suggestions = suggestions
    }
}

extension CodeStatsFactTable: Codable {
    private enum CodingKeys: String, CodingKey {
        case repositories, languages, commits, changes, bulkThreshold, duplicateRepositories
        case suggestions
    }

    private struct CommitColumns: Codable {
        var sha: [String] = []
        var subject: [String] = []
        var day: [Int] = []
        var hour: [Int] = []
        var repository: [Int] = []
        var flags: [Int] = []
        var files: [Int] = []
        var lfsFiles: [Int] = []
        var exclusion: [Int] = []
        var changes: [Int] = []
    }

    private struct ChangeColumns: Codable {
        var language: [Int] = []
        var category: [Int] = []
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
        duplicateRepositories = try container.decode(
            [CodeStatsDuplicateRepository].self, forKey: .duplicateRepositories)
        suggestions = try container.decode(
            [CodeStatsIdentitySuggestion].self, forKey: .suggestions)
        let columns = try container.decode(CommitColumns.self, forKey: .commits)
        let changes = try container.decode(ChangeColumns.self, forKey: .changes)
        let count = columns.sha.count
        let changeCount = changes.language.count
        guard columns.subject.count == count,
            [
                columns.day, columns.hour, columns.repository, columns.flags, columns.files,
                columns.lfsFiles, columns.exclusion, columns.changes,
            ].allSatisfy({ $0.count == count }),
            [changes.category, changes.added, changes.updated, changes.deleted, changes.raw]
                .allSatisfy({ $0.count == changeCount }),
            columns.changes.allSatisfy({ $0 >= 0 }),
            columns.changes.reduce(0, +) == changeCount
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .commits, in: container, debugDescription: "Fact columns differ in length")
        }
        var offset = 0
        commits = (0..<count).map { index in
            let range = offset..<(offset + columns.changes[index])
            offset = range.upperBound
            return CodeStatsFact(
                sha: columns.sha[index], subject: columns.subject[index], day: columns.day[index],
                hour: columns.hour[index], repository: columns.repository[index],
                flags: CodeStatsCommitFlags(rawValue: columns.flags[index]),
                files: columns.files[index], lfsFiles: columns.lfsFiles[index],
                exclusion: CodeStatsExclusion(rawValue: columns.exclusion[index]),
                changes: range.map { position in
                    CodeStatsFactChange(
                        language: changes.language[position],
                        category: Self.categories.indices.contains(changes.category[position])
                            ? Self.categories[changes.category[position]] : .code,
                        counts: CodeStatsLanguageCounts(
                            added: changes.added[position], updated: changes.updated[position],
                            deleted: changes.deleted[position]),
                        raw: changes.raw[position])
                })
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repositories, forKey: .repositories)
        try container.encode(languages, forKey: .languages)
        try container.encode(bulkThreshold, forKey: .bulkThreshold)
        try container.encode(duplicateRepositories, forKey: .duplicateRepositories)
        try container.encode(suggestions, forKey: .suggestions)
        var columns = CommitColumns()
        var changes = ChangeColumns()
        for commit in commits {
            columns.sha.append(commit.sha)
            columns.subject.append(commit.subject)
            columns.day.append(commit.day)
            columns.hour.append(commit.hour)
            columns.repository.append(commit.repository)
            columns.flags.append(commit.flags.rawValue)
            columns.files.append(commit.files)
            columns.lfsFiles.append(commit.lfsFiles)
            columns.exclusion.append(commit.exclusion?.rawValue ?? 0)
            columns.changes.append(commit.changes.count)
            for change in commit.changes {
                changes.language.append(change.language)
                changes.category.append(Self.categories.firstIndex(of: change.category) ?? 0)
                changes.added.append(change.counts.added)
                changes.updated.append(change.counts.updated)
                changes.deleted.append(change.counts.deleted)
                changes.raw.append(change.raw)
            }
        }
        try container.encode(columns, forKey: .commits)
        try container.encode(changes, forKey: .changes)
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
    case lfs
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
        case .squashIntegrated: "Squash merges counted once"
        case .lfs: "Git LFS files"
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
    public var files: Int?

    public init(
        reason: CodeStatsAuditReason, counted: Bool, commits: Int?, lines: Int?,
        files: Int? = nil
    ) {
        self.reason = reason
        self.counted = counted
        self.commits = commits
        self.lines = lines
        self.files = files
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
