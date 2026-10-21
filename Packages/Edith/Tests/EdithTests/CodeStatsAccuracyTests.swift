import Foundation
import Testing

@testable import EdithKit

@Suite struct CodeStatsAccuracyTests {
    private static let me = ("Octocat", "you@example.com")
    private static let claude = ("Claude", "noreply@anthropic.com")

    private func repository(_ fixture: CodeStatsGitFixture, _ name: String) async throws -> (
        URL, CodeStatsRepository
    ) {
        let url = try await fixture.makeRepository(name)
        return (url, CodeStatsRepository(fullName: name, path: url.path, isBare: false))
    }

    @Test func agentCommitsCountOnlyInRepositoriesTheUserOwns() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let (url, repo) = try await repository(fixture, "octocat/app")
        try await fixture.commit(
            ["a.swift": "let a = 1\n"], in: url, author: Self.me, date: "2026-06-01T10:00:00Z")
        try await fixture.commit(
            ["b.swift": "let b = 2\nlet c = 3\n"], in: url, author: Self.claude,
            date: "2026-06-02T10:00:00Z")
        let identity = CodeStatsGitFixture.me

        let owned = try await fixture.tool.commits(
            in: repo, attribution: CodeStatsAttribution(identity: identity, owned: true))
        #expect(owned.count == 2)
        #expect(owned.filter { $0.flags.contains(.agentAssisted) }.count == 1)

        let foreign = try await fixture.tool.commits(
            in: repo, attribution: CodeStatsAttribution(identity: identity, owned: false))
        #expect(foreign.count == 1)
        #expect(foreign.allSatisfy { !$0.flags.contains(.agentAssisted) })
        #expect(CodeStatsAttribution.isOwned("Octocat/app", logins: ["octocat"]))
    }

    @Test func incrementalExtensionParsesOnlyNewCommitsAndMatchesAFullScan() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let (url, repo) = try await repository(fixture, "octocat/lib")
        let attribution = CodeStatsAttribution(identity: CodeStatsGitFixture.me, owned: true)
        try await fixture.commit(
            ["a.swift": "let a = 1\n"], in: url, author: Self.me, date: "2026-06-01T10:00:00Z")
        let before = try await fixture.tool.refState(repo)
        let first = try await fixture.tool.commits(in: repo, attribution: attribution)
        try await fixture.commit(
            ["b.swift": "let b = 2\n"], in: url, author: Self.me, date: "2026-06-03T10:00:00Z")

        #expect(await fixture.tool.canExtend(repo, from: before.tips))
        let added = try await fixture.tool.commits(
            in: repo, attribution: attribution, excluding: before.tips)
        let full = try await fixture.tool.commits(in: repo, attribution: attribution)
        #expect(added.count == 1)
        #expect(Set((first + added).map(\.sha)) == Set(full.map(\.sha)))
        #expect(try await fixture.tool.refState(repo).fingerprint != before.fingerprint)
    }

    @Test func rewrittenHistoryForcesAFullRescan() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let (url, repo) = try await repository(fixture, "octocat/rewrite")
        try await fixture.commit(
            ["a.swift": "let a = 1\n"], in: url, author: Self.me, date: "2026-06-01T10:00:00Z")
        try await fixture.commit(
            ["b.swift": "let b = 2\n"], in: url, author: Self.me, date: "2026-06-02T10:00:00Z")
        let before = try await fixture.tool.refState(repo)
        try await fixture.git(["reset", "-q", "--hard", "HEAD~1"], in: url)
        try await fixture.commit(
            ["c.swift": "let c = 3\n"], in: url, author: Self.me, date: "2026-06-03T10:00:00Z")

        #expect(await fixture.tool.canExtend(repo, from: before.tips) == false)
        #expect(await fixture.tool.canExtend(repo, from: []) == false)
    }

    @Test func squashMergedBranchCommitsAreIntegratedButOpenWorkIsNot() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let (url, repo) = try await repository(fixture, "octocat/squash")
        try await fixture.commit(
            ["base.swift": "let base = 0\n"], in: url, author: Self.me,
            date: "2026-06-01T10:00:00Z")
        try await fixture.git(["checkout", "-q", "-b", "feature"], in: url)
        try await fixture.commit(
            ["f.swift": "let f = 1\n"], in: url, author: Self.me, date: "2026-06-02T10:00:00Z")
        try await fixture.commit(
            ["f.swift": "let f = 1\nlet g = 2\n"], in: url, author: Self.me,
            date: "2026-06-03T10:00:00Z")
        let featureCommits = Set(
            try await fixture.git(["rev-list", "feature", "^main"], in: url)
                .split(separator: "\n").map(String.init))
        try await fixture.git(["checkout", "-q", "-b", "open", "main"], in: url)
        try await fixture.commit(
            ["o.swift": "let o = 9\n"], in: url, author: Self.me, date: "2026-06-04T10:00:00Z")
        try await fixture.git(["checkout", "-q", "main"], in: url)
        try await fixture.git(["merge", "-q", "--squash", "feature"], in: url)
        try await fixture.git(
            ["commit", "-q", "-m", "feature (#1)"], in: url, author: Self.me,
            date: "2026-06-05T10:00:00Z")

        let objectsBefore = try await fixture.git(["count-objects", "-v"], in: url)
        let integrated = try await fixture.tool.integratedCommits(in: repo)
        #expect(featureCommits.count == 2)
        #expect(integrated == featureCommits)
        #expect(try await fixture.git(["count-objects", "-v"], in: url) == objectsBefore)
    }

    @Test func commitsThatOnlyTouchExcludedFilesStillCountAsCommits() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let (url, repo) = try await repository(fixture, "octocat/lockfiles")
        try await fixture.commit(
            ["a.swift": "let a = 1\n"], in: url, author: Self.me, date: "2026-06-01T10:00:00Z")
        try await fixture.commit(
            ["package-lock.json": "{\"lockfileVersion\": 3}\n"], in: url, author: Self.me,
            date: "2026-06-02T10:00:00Z", message: "bump lockfile")
        let commits = try await fixture.tool.commits(
            in: repo,
            attribution: CodeStatsAttribution(identity: CodeStatsGitFixture.me, owned: true))
        #expect(commits.count == 2)
        let lockOnly = commits.first { $0.subject == "bump lockfile" }
        #expect(lockOnly?.totals.authored == 0)
        #expect(lockOnly?.day == "2026-06-02")
    }
}

@Suite struct CodeStatsSquashReplacementTests {
    private static let me = ("Octocat", "you@example.com")
    private static let other = ("Hubot", "hubot@example.com")

    @Test func aVerifiedPullRequestSquashGivesBackItsOriginalDatedCommits() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let url = try await fixture.makeRepository("octocat/reel")
        let repo = CodeStatsRepository(fullName: "octocat/reel", path: url.path, isBare: false)
        try await fixture.commit(
            ["base.swift": "let base = 0\n"], in: url, author: Self.me,
            date: "2026-06-01T10:00:00Z")
        try await fixture.git(["checkout", "-q", "-b", "planets"], in: url)
        try await fixture.commit(
            ["p.swift": "let p = 1\n"], in: url, author: Self.me, date: "2026-06-02T10:00:00Z")
        try await fixture.commit(
            ["q.swift": "let q = 2\n"], in: url, author: Self.other,
            date: "2026-06-03T10:00:00Z")
        try await fixture.commit(
            ["p.swift": "let p = 1\nlet r = 3\n"], in: url, author: Self.me,
            date: "2026-06-04T10:00:00Z")
        let tip = try await fixture.git(["rev-parse", "HEAD"], in: url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await fixture.git(["checkout", "-q", "main"], in: url)
        try await fixture.commit(
            ["main.swift": "let m = 9\n"], in: url, author: Self.me,
            date: "2026-06-05T10:00:00Z")
        try await fixture.git(["merge", "-q", "--squash", "planets"], in: url)
        try await fixture.git(
            ["commit", "-q", "-m", "feat: planets (#74)"], in: url, author: Self.me,
            date: "2026-06-21T10:00:00Z")
        try await fixture.commit(
            ["late.swift": "let l = 0\n"], in: url, author: Self.me,
            date: "2026-06-22T10:00:00Z", message: "unrelated (#75)")
        try await fixture.git(["update-ref", "refs/pull/74/head", tip], in: url)
        try await fixture.git(["update-ref", "refs/pull/75/head", tip], in: url)
        try await fixture.git(["branch", "-q", "-D", "planets"], in: url)

        let attribution = CodeStatsAttribution(identity: CodeStatsGitFixture.me, owned: false)
        let candidates = try await fixture.tool.candidateCommits(
            in: repo, attribution: attribution)
        let squashes = try await fixture.tool.squashes(
            in: repo, candidates: candidates, attribution: attribution)

        #expect(squashes.count == 1)
        let squash = try #require(squashes.first)
        #expect(candidates.first { $0.sha == squash.sha }?.header.hasSuffix("(#74)") == true)
        let originals = try await fixture.tool.commits(
            in: repo, candidates: squash.originals, attribution: attribution)
        #expect(originals.map(\.day).sorted() == ["2026-06-02", "2026-06-04"])

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let all = try await fixture.tool.commits(in: repo, attribution: attribution)
        let table = CodeStatsFactBuilder.build(
            commits: all + originals, replaced: [squash.sha], calendar: utc)
        let days = Set(
            table.commits.filter { $0.exclusion == nil }.map {
                CodeStatsDay(ordinal: $0.day).string
            })
        #expect(days == ["2026-06-01", "2026-06-02", "2026-06-04", "2026-06-05", "2026-06-22"])
        #expect(CodeStatsAuditBuilder.build(table: table).entry(.squashIntegrated)?.commits == 1)
    }
}
