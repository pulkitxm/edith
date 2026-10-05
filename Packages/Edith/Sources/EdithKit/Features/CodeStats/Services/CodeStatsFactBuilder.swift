import Foundation

public enum CodeStatsFactBuilder {
    public static let minimumBulkLines = 20_000
    public static let bulkPercentile = 0.995
    public static let bulkFileLimit = 400
    public static let largestCount = 200
    public static let duplicateRepositoryFraction = 0.5
    public static let duplicateRepositoryMinimum = 3

    private struct Key: Hashable {
        let day: Int
        let hour: Int
        let repository: Int
        let language: Int
        let category: CodeStatsCategory
        let flags: CodeStatsCommitFlags
    }

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    public static func build(
        commits: [CodeStatsCommit], integrated: Set<String> = [],
        suggestions: [CodeStatsIdentitySuggestion] = []
    ) -> CodeStatsFactTable {
        let ordered = commits.sorted {
            ($0.timestamp, $0.repository, $0.sha) < ($1.timestamp, $1.repository, $1.sha)
        }
        var seenSHAs = Set<String>()
        var seenFingerprints = Set<String>()
        var integratedTally = CodeStatsTally()
        var duplicateTally = CodeStatsTally()
        var fingerprints: [String: Set<String>] = [:]
        var firstSeen: [String: Int] = [:]
        var kept: [CodeStatsCommit] = []
        for commit in ordered {
            if let fingerprint = commit.fingerprint {
                fingerprints[commit.repository, default: []].insert(fingerprint)
            }
            firstSeen[commit.repository] = min(
                firstSeen[commit.repository] ?? commit.timestamp, commit.timestamp)
            guard seenSHAs.insert(commit.sha).inserted else { continue }
            if integrated.contains(commit.sha) {
                integratedTally.add(commits: 1, lines: commit.totals.authored)
                continue
            }
            if let fingerprint = commit.fingerprint,
                !seenFingerprints.insert(fingerprint).inserted
            {
                duplicateTally.add(commits: 1, lines: commit.totals.authored)
                continue
            }
            kept.append(commit)
        }
        let threshold = bulkThreshold(kept.map(\.totals.authored))
        let repositories = Set(kept.map(\.repository)).sorted()
        let languages = Set(kept.flatMap { $0.changes.map(\.language) }).sorted()
        let repositoryIndex = Dictionary(
            uniqueKeysWithValues: repositories.enumerated().map { ($1, $0) })
        let languageIndex = Dictionary(
            uniqueKeysWithValues: languages.enumerated().map { ($1, $0) })
        var rows: [CodeStatsFact] = []
        var positions: [Key: Int] = [:]
        var largest: [CodeStatsFactCommit] = []
        func add(_ key: Key, commits: Int, counts: CodeStatsLanguageCounts, raw: Int) {
            if let position = positions[key] {
                rows[position].commits += commits
                rows[position].counts.add(counts)
                rows[position].raw += raw
                return
            }
            positions[key] = rows.count
            rows.append(
                CodeStatsFact(
                    day: key.day, hour: key.hour, repository: key.repository,
                    language: key.language, category: key.category, flags: key.flags,
                    commits: commits, counts: counts, raw: raw))
        }
        for commit in kept {
            guard let day = CodeStatsDay(commit.day),
                let repository = repositoryIndex[commit.repository]
            else { continue }
            var flags = commit.flags
            let totals = commit.totals
            if totals.authored > threshold || commit.files > bulkFileLimit { flags.insert(.bulk) }
            let primary = primaryChange(commit)
            add(
                Key(
                    day: day.ordinal, hour: commit.hour, repository: repository,
                    language: primary.flatMap { languageIndex[$0.language] }
                        ?? CodeStatsFactTable.noLanguage,
                    category: primary?.category ?? .code, flags: flags),
                commits: 1, counts: .zero, raw: 0)
            for change in commit.changes {
                add(
                    Key(
                        day: day.ordinal, hour: commit.hour, repository: repository,
                        language: languageIndex[change.language] ?? CodeStatsFactTable.noLanguage,
                        category: change.category, flags: flags),
                    commits: 0, counts: change.counts, raw: change.raw.authored)
            }
            largest.append(
                CodeStatsFactCommit(
                    sha: commit.sha, repository: commit.repository, day: commit.day,
                    subject: commit.subject, lines: totals.authored,
                    raw: commit.rawTotals.authored, files: commit.files, flags: flags))
        }
        largest.sort { ($0.raw, $1.sha) > ($1.raw, $0.sha) }
        return CodeStatsFactTable(
            repositories: repositories, languages: languages, rows: rows,
            bulkThreshold: threshold, largest: Array(largest.prefix(largestCount)),
            duplicates: duplicateTally, integrated: integratedTally,
            duplicateRepositories: duplicateRepositories(fingerprints, firstSeen: firstSeen),
            suggestions: suggestions)
    }

    public static func bulkThreshold(_ sizes: [Int]) -> Int {
        let sorted = sizes.sorted()
        guard !sorted.isEmpty else { return minimumBulkLines }
        let index = Int((Double(sorted.count - 1) * bulkPercentile).rounded(.down))
        return max(minimumBulkLines, sorted[index])
    }

    static func primaryChange(_ commit: CodeStatsCommit) -> CodeStatsChange? {
        let authored = commit.changes.filter { $0.category != .generated }
        return (authored.isEmpty ? commit.changes : authored).max {
            ($0.counts.authored, $0.raw.authored, $1.language)
                < ($1.counts.authored, $1.raw.authored, $0.language)
        }
    }

    static func duplicateRepositories(
        _ fingerprints: [String: Set<String>], firstSeen: [String: Int]
    ) -> [CodeStatsDuplicateRepository] {
        var holders: [String: [String]] = [:]
        for (repository, values) in fingerprints {
            for value in values { holders[value, default: []].append(repository) }
        }
        var pairs: [Pair: Int] = [:]
        for repositories in holders.values where repositories.count > 1 {
            let sorted = repositories.sorted()
            for first in sorted.indices {
                for second in sorted.indices where second > first {
                    pairs[Pair(first: sorted[first], second: sorted[second]), default: 0] += 1
                }
            }
        }
        return pairs.compactMap { pair, shared -> CodeStatsDuplicateRepository? in
            guard shared >= duplicateRepositoryMinimum else { return nil }
            let firstKey = (
                firstSeen[pair.first] ?? 0, -(fingerprints[pair.first]?.count ?? 0), pair.first
            )
            let secondKey = (
                firstSeen[pair.second] ?? 0, -(fingerprints[pair.second]?.count ?? 0),
                pair.second
            )
            let original = firstKey <= secondKey ? pair.first : pair.second
            let copy = original == pair.first ? pair.second : pair.first
            let fraction = Double(shared) / Double(max(fingerprints[copy]?.count ?? 1, 1))
            guard fraction >= duplicateRepositoryFraction else { return nil }
            return CodeStatsDuplicateRepository(
                repository: copy, original: original, shared: shared, fraction: fraction)
        }.sorted { ($0.shared, $1.repository) > ($1.shared, $0.repository) }
    }
}

public enum CodeStatsAuditBuilder {
    public static func build(
        table: CodeStatsFactTable, filter: CodeStatsFilter = .default
    ) -> CodeStatsAudit {
        var counted = CodeStatsTally()
        let scoped =
            !filter.repositories.isEmpty || !filter.owners.isEmpty || !filter.languages.isEmpty
            || !filter.excludedRepositories.isEmpty
        var raw =
            scoped
            ? CodeStatsTally()
            : CodeStatsTally(
                commits: table.duplicates.commits + table.integrated.commits,
                lines: table.duplicates.lines + table.integrated.lines)
        let repositoryAllowed = table.repositories.map { name in
            !filter.excludedRepositories.contains(name)
                && (filter.repositories.isEmpty || filter.repositories.contains(name))
                && (filter.owners.isEmpty
                    || filter.owners.contains(
                        name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name))
        }
        let languageAllowed = table.languages.map {
            filter.languages.isEmpty || filter.languages.contains($0)
        }
        var flagged: [CodeStatsAuditReason: CodeStatsTally] = [:]
        var categories: [CodeStatsCategory: Int] = [:]
        var whitespace = 0
        let flagReasons: [(CodeStatsCommitFlags, CodeStatsAuditReason)] = [
            (.bulk, .bulk), (.formatting, .formatting), (.agentAssisted, .agentAssisted),
            (.coAuthored, .coAuthored),
        ]
        for row in table.rows {
            guard repositoryAllowed.indices.contains(row.repository),
                repositoryAllowed[row.repository],
                languageAllowed.indices.contains(row.language)
                    ? languageAllowed[row.language] : filter.languages.isEmpty
            else { continue }
            raw.add(commits: row.commits, lines: row.raw)
            categories[row.category, default: 0] += row.counts.authored
            if row.category != .generated { whitespace += max(row.raw - row.counts.authored, 0) }
            let lines = filter.categories.contains(row.category) ? row.counts.authored : 0
            for (flag, reason) in flagReasons where row.flags.contains(flag) {
                flagged[reason, default: CodeStatsTally()].add(commits: row.commits, lines: lines)
            }
            guard row.flags.isDisjoint(with: filter.excludedCommitFlags) else { continue }
            counted.add(
                commits: row.commits,
                lines: row.flags.isDisjoint(with: filter.excludedLineFlags) ? lines : 0)
        }
        let included: [CodeStatsAuditReason: Bool] = [
            .bulk: filter.includeBulk, .formatting: filter.includeFormatting,
            .agentAssisted: filter.includeAgentAssisted, .coAuthored: filter.includeCoAuthored,
        ]
        var entries = flagReasons.map { _, reason in
            CodeStatsAuditEntry(
                reason: reason, counted: included[reason] ?? false,
                commits: flagged[reason]?.commits ?? 0, lines: flagged[reason]?.lines ?? 0)
        }
        let categoryReasons: [(CodeStatsCategory, CodeStatsAuditReason)] = [
            (.generated, .generated), (.data, .data), (.markup, .markup), (.docs, .docs),
        ]
        entries += categoryReasons.map { category, reason in
            CodeStatsAuditEntry(
                reason: reason, counted: filter.categories.contains(category), commits: nil,
                lines: categories[category] ?? 0)
        }
        entries += [
            CodeStatsAuditEntry(
                reason: .whitespace, counted: false, commits: nil, lines: whitespace),
            CodeStatsAuditEntry(
                reason: .duplicate, counted: false, commits: table.duplicates.commits,
                lines: table.duplicates.lines),
            CodeStatsAuditEntry(
                reason: .squashIntegrated, counted: false, commits: table.integrated.commits,
                lines: table.integrated.lines),
            CodeStatsAuditEntry(
                reason: .unmatchedIdentity, counted: false,
                commits: table.suggestions.reduce(0) { $0 + $1.commits }, lines: nil),
        ]
        return CodeStatsAudit(
            filter: filter, counted: counted, raw: raw, bulkThreshold: table.bulkThreshold,
            entries: entries.sorted {
                CodeStatsAuditReason.allCases.firstIndex(of: $0.reason) ?? 0
                    < CodeStatsAuditReason.allCases.firstIndex(of: $1.reason) ?? 0
            },
            duplicateRepositories: table.duplicateRepositories, suggestions: table.suggestions)
    }
}
