import EdithExtensionSupport
import Foundation

public enum CodeStatsFactBuilder {
    public static let minimumBulkLines = 20_000
    public static let bulkPercentile = 0.995
    public static let bulkFileLimit = 400
    public static let duplicateRepositoryFraction = 0.5
    public static let duplicateRepositoryMinimum = 3

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    public static func build(
        commits: [CodeStatsCommit], integrated: Set<String> = [], replaced: Set<String> = [],
        suggestions: [CodeStatsIdentitySuggestion] = [], calendar: Calendar = .current
    ) -> CodeStatsFactTable {
        let ordered = commits.sorted {
            ($0.timestamp, $0.repository, $0.sha) < ($1.timestamp, $1.repository, $1.sha)
        }
        var seenSHAs = Set<String>()
        var seenFingerprints = Set<String>()
        var fingerprints: [String: Set<String>] = [:]
        var firstSeen: [String: Int] = [:]
        var kept: [(commit: CodeStatsCommit, exclusion: CodeStatsExclusion?)] = []
        for commit in ordered {
            if let fingerprint = commit.fingerprint {
                fingerprints[commit.repository, default: []].insert(fingerprint)
            }
            firstSeen[commit.repository] = min(
                firstSeen[commit.repository] ?? commit.timestamp, commit.timestamp)
            guard seenSHAs.insert(commit.sha).inserted else { continue }
            if integrated.contains(commit.sha) || replaced.contains(commit.sha) {
                kept.append((commit, .integrated))
            } else if let fingerprint = commit.fingerprint,
                !seenFingerprints.insert(fingerprint).inserted
            {
                kept.append((commit, .duplicate))
            } else {
                kept.append((commit, nil))
            }
        }
        let threshold = bulkThreshold(
            kept.filter { $0.exclusion == nil }.map(\.commit.totals.authored))
        let repositories = Set(kept.map(\.commit.repository)).sorted()
        let languages = Set(kept.flatMap { $0.commit.changes.map(\.language) }).sorted()
        let repositoryIndex = Dictionary(
            uniqueKeysWithValues: repositories.enumerated().map { ($1, $0) })
        let languageIndex = Dictionary(
            uniqueKeysWithValues: languages.enumerated().map { ($1, $0) })
        var facts: [CodeStatsFact] = []
        facts.reserveCapacity(kept.count)
        for (commit, exclusion) in kept {
            let (day, hour) = moment(commit, calendar: calendar)
            guard let day, let repository = repositoryIndex[commit.repository] else { continue }
            var flags = commit.flags
            if commit.totals.authored > threshold || commit.files > bulkFileLimit {
                flags.insert(.bulk)
            }
            facts.append(
                CodeStatsFact(
                    sha: commit.sha, subject: commit.subject, day: day.ordinal, hour: hour,
                    repository: repository, flags: flags, files: commit.files,
                    lfsFiles: commit.lfsFiles, exclusion: exclusion,
                    changes: commit.changes.map {
                        CodeStatsFactChange(
                            language: languageIndex[$0.language] ?? CodeStatsFactTable.noLanguage,
                            category: $0.category, counts: $0.counts, raw: $0.raw.authored)
                    }))
        }
        return CodeStatsFactTable(
            repositories: repositories, languages: languages, commits: facts,
            bulkThreshold: threshold,
            duplicateRepositories: duplicateRepositories(fingerprints, firstSeen: firstSeen),
            suggestions: suggestions)
    }

    static func moment(
        _ commit: CodeStatsCommit, calendar: Calendar
    ) -> (day: CodeStatsDay?, hour: Int) {
        guard commit.timestamp > 0 else { return (CodeStatsDay(commit.day), commit.hour) }
        let date = Date(timeIntervalSince1970: TimeInterval(commit.timestamp))
        return (
            CodeStatsDay(date: date, calendar: calendar), calendar.component(.hour, from: date)
        )
    }

    public static func bulkThreshold(_ sizes: [Int]) -> Int {
        let sorted = sizes.sorted()
        guard !sorted.isEmpty else { return minimumBulkLines }
        let index = Int((Double(sorted.count - 1) * bulkPercentile).rounded(.down))
        return max(minimumBulkLines, sorted[index])
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
        table: CodeStatsFactTable, filter: CodeStatsFilter = .default,
        days: ClosedRange<CodeStatsDay>? = nil
    ) -> CodeStatsAudit {
        let scope = CodeStatsScope(table: table, filter: filter)
        var counted = CodeStatsTally()
        var raw = CodeStatsTally()
        var duplicates = CodeStatsTally()
        var integrated = CodeStatsTally()
        var lfs = CodeStatsTally()
        var lfsFiles = 0
        var flagged: [CodeStatsAuditReason: CodeStatsTally] = [:]
        var categories: [CodeStatsCategory: Int] = [:]
        var whitespace = 0
        let flagReasons: [(CodeStatsCommitFlags, CodeStatsAuditReason)] = [
            (.bulk, .bulk), (.formatting, .formatting), (.agentAssisted, .agentAssisted),
            (.coAuthored, .coAuthored),
        ]
        for fact in table.commits {
            if let days, !days.contains(CodeStatsDay(ordinal: fact.day)) { continue }
            guard let changes = scope.changes(of: fact) else { continue }
            raw.add(commits: 1, lines: changes.reduce(0) { $0 + $1.raw })
            let authored = changes.reduce(0) {
                $0 + ($1.category == .generated ? 0 : $1.counts.authored)
            }
            switch fact.exclusion {
            case .duplicate:
                duplicates.add(commits: 1, lines: authored)
                continue
            case .integrated:
                integrated.add(commits: 1, lines: authored)
                continue
            case nil:
                break
            }
            if fact.lfsFiles > 0 {
                lfs.add(commits: 1)
                lfsFiles += fact.lfsFiles
            }
            var lines = 0
            for change in changes {
                categories[change.category, default: 0] += change.counts.authored
                if change.category != .generated {
                    whitespace += max(change.raw - change.counts.authored, 0)
                }
                if filter.categories.contains(change.category) { lines += change.counts.authored }
            }
            for (flag, reason) in flagReasons where fact.flags.contains(flag) {
                flagged[reason, default: CodeStatsTally()].add(commits: 1, lines: lines)
            }
            guard fact.flags.isDisjoint(with: filter.excludedCommitFlags) else { continue }
            counted.add(
                commits: 1,
                lines: fact.flags.isDisjoint(with: filter.excludedLineFlags) ? lines : 0)
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
                reason: .duplicate, counted: false, commits: duplicates.commits,
                lines: duplicates.lines),
            CodeStatsAuditEntry(
                reason: .squashIntegrated, counted: false, commits: integrated.commits,
                lines: integrated.lines),
            CodeStatsAuditEntry(
                reason: .lfs, counted: false, commits: lfs.commits, lines: nil, files: lfsFiles),
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
