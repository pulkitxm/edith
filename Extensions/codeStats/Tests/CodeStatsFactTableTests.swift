@testable import CodeStatsExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct CodeStatsFactTableTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let today = Calendar(identifier: .gregorian).date(
        from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 6, day: 30, hour: 12))!

    private func commit(
        _ sha: String, repository: String = "octo/app", day: String = "2026-06-01",
        timestamp: Int = 0, files: Int = 1, flags: CodeStatsCommitFlags = [],
        fingerprint: String? = nil, changes: [CodeStatsChange]
    ) -> CodeStatsCommit {
        CodeStatsCommit(
            sha: sha, day: day, hour: 10, repository: repository, timestamp: timestamp,
            subject: sha, files: files, fingerprint: fingerprint, flags: flags, changes: changes)
    }

    private func code(_ language: String, _ added: Int, raw: Int? = nil) -> CodeStatsChange {
        CodeStatsChange(
            language: language, category: .code, counts: CodeStatsLanguageCounts(added: added),
            raw: CodeStatsLanguageCounts(added: raw ?? added))
    }

    private func change(_ language: String, _ category: CodeStatsCategory, _ added: Int)
        -> CodeStatsChange
    {
        CodeStatsChange(
            language: language, category: category, counts: CodeStatsLanguageCounts(added: added))
    }

    private func report(_ table: CodeStatsFactTable, _ filter: CodeStatsFilter = .default)
        -> CodeStatsReport
    {
        CodeStatsReportBuilder.build(
            table: table, filter: filter, range: .all, today: Self.today, calendar: Self.calendar)
    }

    @Test func bulkCommitsStillCountButTheirLinesDoNotByDefault() {
        let table = CodeStatsFactBuilder.build(commits: [
            commit("small", changes: [code("Swift", 120)]),
            commit("import", day: "2026-06-02", changes: [code("Swift", 25_000)]),
            commit("wide", day: "2026-06-03", files: 401, changes: [code("Swift", 400)]),
        ])
        #expect(table.bulkThreshold == 20_000)
        let flagged = table.largest.filter { $0.flags.contains(.bulk) }.map(\.sha).sorted()
        #expect(flagged == ["import", "wide"])
        let counted = report(table).totals
        #expect(counted.commits == 3)
        #expect(counted.authored == 120)
        var withBulk = CodeStatsFilter.default
        withBulk.includeBulk = true
        #expect(report(table, withBulk).totals.authored == 25_520)
    }

    @Test func theBulkThresholdFollowsTheUsersLargestCommits() {
        let sizes = (1...1_000).map { $0 * 100 }
        #expect(CodeStatsFactBuilder.bulkThreshold(sizes) == 99_500)
        #expect(CodeStatsFactBuilder.bulkThreshold([10, 20]) == 20_000)
        #expect(CodeStatsFactBuilder.bulkThreshold([]) == 20_000)
    }

    @Test func formattingAgentAndCoAuthoredTogglesApply() {
        let table = CodeStatsFactBuilder.build(commits: [
            commit("mine", changes: [code("Swift", 10)]),
            commit("fmt", flags: .formatting, changes: [code("Swift", 7)]),
            commit("agent", flags: .agentAssisted, changes: [code("Swift", 5)]),
            commit("pair", flags: .coAuthored, changes: [code("Swift", 3)]),
        ])
        let defaults = report(table).totals
        #expect(defaults.commits == 4)
        #expect(defaults.authored == 18)
        var filter = CodeStatsFilter.default
        filter.includeFormatting = true
        filter.includeAgentAssisted = false
        filter.includeCoAuthored = false
        let custom = report(table, filter).totals
        #expect(custom.commits == 2)
        #expect(custom.authored == 17)
    }

    @Test func categoriesFilterLinesButNotCommits() {
        let table = CodeStatsFactBuilder.build(commits: [
            commit(
                "mixed",
                changes: [
                    code("TypeScript", 40), change("JSON", .data, 900), change("HTML", .markup, 30),
                    change("Markdown", .docs, 12), change("TypeScript", .generated, 5_000),
                ])
        ])
        let defaults = report(table)
        #expect(defaults.totals.commits == 1)
        #expect(defaults.totals.authored == 82)
        #expect(defaults.languages.map(\.language) == ["TypeScript", "HTML", "Markdown"])
        var codeOnly = CodeStatsFilter.default
        codeOnly.categories = [.code]
        #expect(report(table, codeOnly).totals.authored == 40)
        var withData = CodeStatsFilter.default
        withData.categories.insert(.data)
        #expect(report(table, withData).totals.authored == 982)
    }

    @Test func repositoryOwnerAndLanguageFiltersNarrowTheReport() {
        let table = CodeStatsFactBuilder.build(commits: [
            commit("a", repository: "octo/app", changes: [code("Swift", 10)]),
            commit("b", repository: "octo/web", changes: [code("TypeScript", 20)]),
            commit("c", repository: "acme/api", changes: [code("Go", 30), code("Swift", 1)]),
        ])
        var byRepository = CodeStatsFilter.default
        byRepository.repositories = ["octo/web"]
        #expect(report(table, byRepository).totals.authored == 20)
        var byOwner = CodeStatsFilter.default
        byOwner.owners = ["octo"]
        let owned = report(table, byOwner)
        #expect(owned.totals.commits == 2)
        #expect(owned.repositories.map(\.repository) == ["octo/app", "octo/web"])
        var byLanguage = CodeStatsFilter.default
        byLanguage.languages = ["Swift"]
        let swift = report(table, byLanguage)
        #expect(swift.totals.commits == 1)
        #expect(swift.totals.authored == 11)
        #expect(swift.languages.map(\.language) == ["Swift"])
    }

    @Test func identicalContentCountsOnceAndTheEarliestWins() {
        let table = CodeStatsFactBuilder.build(commits: [
            commit(
                "copy", repository: "octo/backup", day: "2026-06-05", timestamp: 200,
                fingerprint: "same", changes: [code("Swift", 95_733)]),
            commit(
                "first", repository: "octo/app", day: "2026-06-01", timestamp: 100,
                fingerprint: "same", changes: [code("Swift", 95_733)]),
            commit(
                "fork", repository: "other/app", timestamp: 100, fingerprint: "same",
                changes: [code("Swift", 95_733)]),
            commit("first", repository: "zeta/app", timestamp: 100, changes: [code("Swift", 1)]),
        ])
        #expect(table.repositories == ["octo/app"])
        #expect(table.duplicates == CodeStatsTally(commits: 2, lines: 191_466))
        #expect(report(table).totals.commits == 1)
        #expect(table.largest.map(\.day) == ["2026-06-01"])
    }

    @Test func squashIntegratedBranchCommitsAreLeftOut() {
        let table = CodeStatsFactBuilder.build(
            commits: [
                commit("squash", changes: [code("Swift", 50)]),
                commit("wip1", changes: [code("Swift", 30)]),
                commit("wip2", changes: [code("Swift", 20)]),
            ], integrated: ["wip1", "wip2"])
        #expect(table.integrated == CodeStatsTally(commits: 2, lines: 50))
        #expect(
            report(table).totals
                == report(
                    CodeStatsFactBuilder.build(commits: [
                        commit("squash", changes: [code("Swift", 50)])
                    ])
                ).totals)
    }

    @Test func repositoriesSharingMostFingerprintsAreReportedAsCopies() {
        var commits: [CodeStatsCommit] = []
        for index in 0..<4 {
            let content = [code("Swift", 10)]
            commits.append(
                commit(
                    "o\(index)", repository: "octo/app", timestamp: index, fingerprint: "f\(index)",
                    changes: content))
            commits.append(
                commit(
                    "c\(index)", repository: "octo/app-copy", timestamp: 100 + index,
                    fingerprint: "f\(index)", changes: content))
        }
        commits.append(
            commit("u", repository: "octo/app", timestamp: 9, fingerprint: "u", changes: []))
        let table = CodeStatsFactBuilder.build(commits: commits)
        #expect(
            table.duplicateRepositories == [
                CodeStatsDuplicateRepository(
                    repository: "octo/app-copy", original: "octo/app", shared: 4, fraction: 1)
            ])
    }

    @Test func aggregationMatchesADirectSum() {
        var commits: [CodeStatsCommit] = []
        var expectedCommits: [String: Int] = [:]
        var expectedLines: [String: Int] = [:]
        for index in 0..<300 {
            let day = String(format: "2026-05-%02d", index % 28 + 1)
            let repository = ["octo/a", "octo/b", "acme/c"][index % 3]
            let lines = index * 7 % 113
            commits.append(
                commit(
                    "s\(index)", repository: repository, day: day,
                    changes: [code(index.isMultiple(of: 2) ? "Swift" : "Go", lines)]))
            expectedCommits[day, default: 0] += 1
            expectedLines[repository, default: 0] += lines
        }
        let built = report(CodeStatsFactBuilder.build(commits: commits))
        let daily = Dictionary(uniqueKeysWithValues: built.daily.map { ($0.day, $0.commits) })
        for (day, count) in expectedCommits { #expect(daily[day] == count) }
        let lines = Dictionary(
            uniqueKeysWithValues: built.repositories.map { ($0.repository, $0.counts.authored) })
        #expect(lines == expectedLines)
        #expect(built.totals.commits == 300)
        #expect(built.punchcard.joined().reduce(0, +) == 300)
    }

    @Test func columnarEncodingRoundTrips() throws {
        let table = CodeStatsFactBuilder.build(
            commits: [
                commit(
                    "a", flags: [.agentAssisted, .formatting], fingerprint: "x",
                    changes: [code("Swift", 3, raw: 9), change("JSON", .data, 4)]),
                commit("b", day: "2026-06-02", changes: []),
            ],
            suggestions: [
                CodeStatsIdentitySuggestion(
                    name: "me", email: "me@host.local", commits: 2, value: "me@host.local",
                    reason: .hostname, score: 90)
            ])
        let decoded = try JSONDecoder().decode(
            CodeStatsFactTable.self, from: JSONEncoder().encode(table))
        #expect(decoded == table)
        #expect(table.rows.contains { $0.language == CodeStatsFactTable.noLanguage })
    }

    @Test func theAuditExplainsCountedAndExcludedWork() {
        let table = CodeStatsFactBuilder.build(
            commits: [
                commit("mine", changes: [code("Swift", 100, raw: 130)]),
                commit("huge", files: 500, changes: [code("Swift", 600)]),
                commit("fmt", flags: .formatting, changes: [code("Swift", 2, raw: 300)]),
                commit("bot", flags: .agentAssisted, changes: [code("Swift", 40)]),
                commit("cfg", changes: [change("JSON", .data, 70), change("C", .generated, 9)]),
                commit("dup", timestamp: 5, fingerprint: "f", changes: [code("Swift", 8)]),
                commit("dup2", timestamp: 6, fingerprint: "f", changes: [code("Swift", 8)]),
                commit("wip", changes: [code("Swift", 11)]),
            ], integrated: ["wip"],
            suggestions: [
                CodeStatsIdentitySuggestion(
                    name: "me", email: "me@host.local", commits: 6, value: "me@host.local",
                    reason: .hostname, score: 90)
            ])
        let audit = CodeStatsAuditBuilder.build(table: table)
        #expect(audit.counted == CodeStatsTally(commits: 6, lines: 148))
        #expect(audit.raw.commits == 8)
        #expect(
            audit.entry(.bulk)
                == CodeStatsAuditEntry(
                    reason: .bulk, counted: false, commits: 1, lines: 600))
        #expect(audit.entry(.formatting)?.lines == 2)
        #expect(
            audit.entry(.agentAssisted)
                == CodeStatsAuditEntry(
                    reason: .agentAssisted, counted: true, commits: 1, lines: 40))
        #expect(audit.entry(.data)?.lines == 70)
        #expect(audit.entry(.data)?.counted == false)
        #expect(audit.entry(.generated)?.lines == 9)
        #expect(audit.entry(.whitespace)?.lines == 328)
        #expect(audit.entry(.duplicate)?.commits == 1)
        #expect(audit.entry(.squashIntegrated)?.lines == 11)
        #expect(audit.entry(.unmatchedIdentity)?.commits == 6)
        let matched = audit.matching(CodeStatsIdentity(emails: ["me@host.local"]))
        #expect(matched.suggestions.isEmpty)
        #expect(matched.entry(.unmatchedIdentity)?.commits == 0)
    }

    @Test func filteringAHundredThousandRowsStaysFast() {
        let repositories = (0..<200).map { "owner\($0 % 20)/repo\($0)" }
        let languages = (0..<40).map { "Language\($0)" }
        let rows = (0..<100_000).map { index in
            CodeStatsFact(
                day: CodeStatsDay(year: 2020, month: 1, day: 1).ordinal + index % 2_300,
                hour: index % 24, repository: index % repositories.count,
                language: index % languages.count,
                category: CodeStatsCategory.allCases[index % CodeStatsCategory.allCases.count],
                flags: CodeStatsCommitFlags(rawValue: index % 16), commits: index % 3 == 0 ? 1 : 0,
                counts: CodeStatsLanguageCounts(added: index % 50, updated: index % 7), raw: 60)
        }
        let table = CodeStatsFactTable(
            repositories: repositories, languages: languages, rows: rows, bulkThreshold: 20_000)
        var filter = CodeStatsFilter.default
        filter.owners = ["owner1", "owner2", "owner3"]
        let started = ProcessInfo.processInfo.systemUptime
        let built = CodeStatsReportBuilder.build(
            table: table, filter: filter, range: .all, today: Self.today,
            calendar: Self.calendar)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(built.totals.commits > 0)
        #expect(elapsed < 1.5, "aggregation took \(elapsed) seconds")
    }
}
