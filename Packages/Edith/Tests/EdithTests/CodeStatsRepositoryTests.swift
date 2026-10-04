@testable import EdithKit
import Foundation
import Testing

@Suite struct CodeStatsDiscoveryTests {
    @Test func findsWorkingTreeAndBareLayoutsAndPrefersTheBareMirror() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let make = { (path: String) in
            try fileManager.createDirectory(
                at: fixture.root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try make("octo/tree/.git")
        try make("octo/bare.git/objects")
        try "ref: refs/heads/main".write(
            to: fixture.root.appendingPathComponent("octo/bare.git/HEAD"), atomically: true,
            encoding: .utf8)
        try make("octo/both/.git")
        try make("octo/both.git/objects")
        try "ref".write(
            to: fixture.root.appendingPathComponent("octo/both.git/HEAD"), atomically: true,
            encoding: .utf8)
        try make("octo/plain/src")
        try make(".hidden/x/.git")
        try make("octo/.partial.git/objects")

        let found = CodeStatsRepositoryDiscovery.discover(root: fixture.root)
        #expect(found.map(\.fullName) == ["octo/bare", "octo/both", "octo/tree"])
        #expect(found.map(\.isBare) == [true, true, false])
        #expect(found[1].path.hasSuffix("octo/both.git"))
        #expect(
            CodeStatsRepositoryDiscovery.discover(root: fixture.root.appendingPathComponent("none"))
                .isEmpty)
        #expect(
            CodeStatsRepositoryDiscovery.mirrorURL(root: fixture.root, fullName: "octo/demo").path
                == fixture.root.appendingPathComponent("octo/demo.git").path)
    }
}

@Suite struct CodeStatsCacheTests {
    private let commit = CodeStatsCommit(sha: "x", day: "2026-06-01", hour: 1, repository: "octo/r")

    @Test func loadingWithoutFilesReturnsNothing() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("missing"))
        #expect(store.loadCaches().isEmpty)
        #expect(store.loadReports().isEmpty)
    }

    @Test func savingThenLoadingRoundTrips() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let store = CodeStatsStore(root: fixture.root)
        let cache = CodeStatsRepositoryCache(
            repository: "octo/r", refsFingerprint: "fp1", identityFingerprint: "id1",
            commits: [commit])
        try store.save(cache)
        #expect(store.loadCaches() == ["octo/r": cache])
        let report = CodeStatsReportBuilder.build(
            commits: [commit], range: .all, today: Date(), calendar: .current)
        try store.saveReports([report])
        #expect(store.loadReports() == [report])
    }

    @Test func freshCommitsRequireMatchingRefsAndIdentity() {
        let cache = CodeStatsRepositoryCache(
            repository: "octo/r", refsFingerprint: "fp1", identityFingerprint: "id1",
            commits: [commit])
        #expect(cache.freshCommits(refs: "fp1", identity: "id1") == [commit])
        #expect(cache.freshCommits(refs: "fp2", identity: "id1") == nil)
        #expect(cache.freshCommits(refs: "fp1", identity: "id2") == nil)
    }

    @Test func staleVersionsAndCorruptFilesAreIgnoredAndPruningKeepsListedRepositories() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let store = CodeStatsStore(root: fixture.root)
        var stale = CodeStatsRepositoryCache(
            repository: "octo/old", refsFingerprint: "a", identityFingerprint: "b", commits: [])
        stale.version = 0
        try store.save(stale)
        let folder = fixture.root.appendingPathComponent("repositories/octo")
        try "{".write(
            to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        #expect(store.loadCaches().isEmpty)
        for name in ["octo/keep", "octo/drop"] {
            try store.save(
                CodeStatsRepositoryCache(
                    repository: name, refsFingerprint: "a", identityFingerprint: "b", commits: []))
        }
        store.removeCaches(except: ["octo/keep"])
        #expect(Array(store.loadCaches().keys) == ["octo/keep"])
    }
}

@Suite struct CodeStatsGitIntegrationTests {
    @Test func extractsOnlyMyCommitsWithDatesHoursRenamesAndExcludedLockFiles() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.makeRepository("octo/demo")
        let me = ("Octocat", "you@example.com")
        try await fixture.commit(
            ["a.ts": "one\ntwo\nthree\n"], in: repository, author: me,
            date: "2026-06-01T09:15:00+00:00")
        try await fixture.commit(
            ["a.ts": "one\nTWO\nthree\nfour\n"], in: repository, author: me,
            date: "2026-06-02T22:30:00+05:30")
        try await fixture.commit(
            ["b.py": "x\n"], in: repository, author: ("Stranger", "s@x.com"),
            date: "2026-06-03T10:00:00+00:00")
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("src"), withIntermediateDirectories: true)
        try await fixture.git(["mv", "a.ts", "src/a.ts"], in: repository)
        try await fixture.commit(
            ["yarn.lock": "lock\n"], in: repository,
            author: ("OCTOCAT", "1+octocat@users.noreply.github.com"),
            date: "2026-06-04T07:00:00+00:00")
        try await fixture.commit(
            ["yarn.lock": "lock\nmore\n"], in: repository, author: me,
            date: "2026-06-05T07:00:00+00:00")

        let found = CodeStatsRepositoryDiscovery.discover(root: fixture.root)
        #expect(found.map(\.fullName) == ["octo/demo"])
        let commits = try await fixture.tool.commits(in: found[0], identity: CodeStatsGitFixture.me)
            .sorted { $0.day < $1.day }

        #expect(commits.map(\.day) == ["2026-06-01", "2026-06-02", "2026-06-04"])
        #expect(commits.map(\.hour) == [9, 22, 7])
        #expect(commits[0].languages == ["TypeScript": CodeStatsLanguageCounts(added: 3)])
        #expect(
            commits[1].languages == ["TypeScript": CodeStatsLanguageCounts(added: 1, updated: 1)])
        #expect(commits[2].languages.isEmpty)
        #expect(commits.allSatisfy { $0.repository == "octo/demo" })
        #expect(try await fixture.tool.commits(in: found[0], identity: CodeStatsIdentity()).isEmpty)

        let authors = try await fixture.tool.authors(in: found[0])
        #expect(authors.first { $0.name == "Octocat" }?.commits == 3)
        #expect(authors.first { $0.email == "s@x.com" }?.commits == 1)
    }

    @Test func theRefsFingerprintChangesWhenRefsChange() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let url = try await fixture.makeRepository("octo/refs")
        try await fixture.commit(
            ["a.go": "package a\n"], in: url, author: ("Octocat", "you@example.com"),
            date: "2026-06-01T09:00:00+00:00")
        let repository = CodeStatsRepository(fullName: "octo/refs", path: url.path, isBare: false)
        let first = try await fixture.tool.refsFingerprint(repository)
        #expect(first.count == 64)
        #expect(try await fixture.tool.refsFingerprint(repository) == first)
        try await fixture.git(["branch", "feature"], in: url)
        #expect(try await fixture.tool.refsFingerprint(repository) != first)
    }
}
