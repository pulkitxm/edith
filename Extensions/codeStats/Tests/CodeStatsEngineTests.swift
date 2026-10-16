@testable import CodeStatsExtension
import EdithExtensionSupport
import Foundation
import Testing

private struct FakeGitHub: CodeStatsGitHubClient {
    var listing: [CodeStatsRemoteRepository]
    var listingDelay: Duration?

    func profile() async throws -> CodeStatsProfile {
        CodeStatsProfile(id: 1, login: "octocat", name: "Octo")
    }

    func emails(for profile: CodeStatsProfile) async -> [String] { [profile.noreplyEmail] }

    func repositories() async throws -> [CodeStatsRemoteRepository] {
        if let listingDelay { try await Task.sleep(for: listingDelay) }
        return listing
    }
}

@Suite struct CodeStatsEngineTests {
    private let me = ("Octocat", "you@example.com")

    private func remote(
        _ name: String, in fixture: CodeStatsGitFixture, day: String = "2024-05-01"
    ) async throws -> (work: URL, remote: URL) {
        let work = try await fixture.makeRepository("work/\(name)")
        try await fixture.commit(
            ["\(name).swift": "let a = 1\n"], in: work, author: me, date: day + "T10:00:00+00:00")
        let remote = fixture.root.appendingPathComponent("remote/\(name).git")
        try await fixture.git(["clone", "--bare", "-q", work.path, remote.path])
        return (work, remote)
    }

    private func mirror(_ fixture: CodeStatsGitFixture, _ path: String = "mirror") throws -> URL {
        let url = fixture.root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func allTime(_ store: CodeStatsStore) -> CodeStatsReport? {
        store.loadReports().first { $0.range == .all }
    }

    @Test func clonesThenFetchesNewCommitsWithMonotonicProgress() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let demo = try await remote("demo", in: fixture)
        let mirror = try mirror(fixture)
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        let github = FakeGitHub(listing: [
            CodeStatsRemoteRepository(
                fullName: "octo/demo", cloneURL: demo.remote.path, sizeKilobytes: 12),
            CodeStatsRemoteRepository(fullName: "octo/fork", cloneURL: "/nowhere", isFork: true),
            CodeStatsRemoteRepository(
                fullName: "octo/broken",
                cloneURL: fixture.root.appendingPathComponent("missing.git").path),
        ])
        let engine = CodeStatsEngine(
            github: github, git: fixture.tool, store: store, progressInterval: 0)
        let settings = CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me)
        let events = CodeStatsLocked([CodeStatsRunProgress]())

        let first = await engine.run(settings: settings) { event in
            events.update { $0.append(event) }
        }
        #expect(first.outcome == .completed)
        #expect(first.profile?.login == "octocat")
        #expect(first.synced == 1)
        #expect(first.failed == 1)
        #expect(first.errors.first?.hasPrefix("octo/broken: ") == true)
        #expect(first.repositories == 1)
        let fileManager = FileManager.default
        #expect(
            fileManager.fileExists(atPath: mirror.appendingPathComponent("octo/demo.git/HEAD").path)
        )
        #expect(
            !fileManager.fileExists(atPath: mirror.appendingPathComponent("octo/fork.git").path))
        #expect(
            try fileManager.contentsOfDirectory(atPath: mirror.appendingPathComponent("octo").path)
                == ["demo.git"])
        #expect(allTime(store)?.totals.commits == 1)
        #expect(store.loadReports().map(\.range) == CodeStatsRange.presets)

        let snapshot = events.update { $0 }
        let fractions = snapshot.map(\.overallFraction)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(fractions.last == 1)
        var phases: [CodeStatsPhase] = []
        for event in snapshot where phases.last != event.phase { phases.append(event.phase) }
        #expect(phases == CodeStatsPhase.allCases)
        #expect(snapshot.last?.skipped == 1)
        #expect(snapshot.last?.listedKilobytes == 12)

        try await fixture.commit(
            ["demo.swift": "let a = 2\nlet b = 3\n"], in: demo.work, author: me,
            date: "2024-05-02T11:00:00+00:00")
        try await fixture.git(["push", "-q", demo.remote.path, "main"], in: demo.work)
        #expect(await engine.run(settings: settings).outcome == .completed)
        #expect(allTime(store)?.totals.commits == 2)
        #expect(allTime(store)?.totals.authored == 3)

        let stranger = CodeStatsSettings(
            folder: mirror.path, identity: CodeStatsIdentity(emails: ["nobody@x.com"]))
        #expect(await engine.run(settings: stranger).outcome == .completed)
        #expect(allTime(store)?.totals.commits == 0)

        let authors = await CodeStatsEngine.authors(
            root: mirror, identity: CodeStatsGitFixture.me, git: fixture.tool)
        #expect(authors.first?.author.commits == 2)
        #expect(authors.first?.countedAsYou == true)
    }

    @Test func cancellationStopsPromptly() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let engine = CodeStatsEngine(
            github: FakeGitHub(listing: [], listingDelay: .seconds(30)), git: fixture.tool,
            store: CodeStatsStore(root: fixture.root.appendingPathComponent("state")),
            progressInterval: 0)
        let settings = CodeStatsSettings(
            folder: try mirror(fixture).path, identity: CodeStatsGitFixture.me)
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task { await engine.run(settings: settings) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(result.github == nil)
        #expect(ProcessInfo.processInfo.systemUptime - started < 5)
    }

    private func hiddenEntries(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
            $0.hasPrefix(".")
        }
    }

    @Test func cancellingMidCloneStopsGitAndRemovesTheStagingFolder() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let mirror = try mirror(fixture)
        let blocking = try fixture.blockingTool(on: "clone")
        let engine = CodeStatsEngine(
            github: FakeGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/huge", cloneURL: "/nowhere/huge.git")
            ]), git: blocking.tool,
            store: CodeStatsStore(root: fixture.root.appendingPathComponent("state")),
            progressInterval: 0)
        let settings = CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me)
        let task = Task { await engine.run(settings: settings) }
        let pid = try #require(await fixture.waitForProcess(blocking.pidFile))
        let owner = mirror.appendingPathComponent("octo")
        #expect(hiddenEntries(owner).count == 1)
        let cancelled = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(ProcessInfo.processInfo.systemUptime - cancelled < 5)
        #expect(try await CodeStatsGitFixture.eventually { kill(pid, 0) != 0 })
        #expect(try await CodeStatsGitFixture.eventually { hiddenEntries(owner).isEmpty })
    }

    @Test func cancellingMidAnalysisStopsTheLogProcess() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let mirror = try mirror(fixture)
        let local = try await fixture.makeRepository("mirror/octo/local")
        try await fixture.commit(
            ["a.swift": "let a = 1\n"], in: local, author: me, date: "2024-05-01T10:00:00+00:00")
        let blocking = try fixture.blockingTool(on: "log")
        let engine = CodeStatsEngine(
            github: nil, git: blocking.tool,
            store: CodeStatsStore(root: fixture.root.appendingPathComponent("state")),
            progressInterval: 0)
        let settings = CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me)
        let task = Task { await engine.run(settings: settings) }
        let pid = try #require(await fixture.waitForProcess(blocking.pidFile))
        let cancelled = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(result.github == .unavailable)
        #expect(ProcessInfo.processInfo.systemUptime - cancelled < 5)
        #expect(try await CodeStatsGitFixture.eventually { kill(pid, 0) != 0 })
    }

    @Test func aStalledFetchTimesOutAndTheRunStillCompletes() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let mirror = try mirror(fixture)
        let local = try await fixture.makeRepository("mirror/octo/slow")
        try await fixture.commit(
            ["a.swift": "let a = 1\n"], in: local, author: me, date: "2024-05-01T10:00:00+00:00")
        let blocking = try fixture.blockingTool(on: "fetch", networkTimeout: 1)
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        let engine = CodeStatsEngine(
            github: FakeGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/slow", cloneURL: "/nowhere/slow.git")
            ]), git: blocking.tool, store: store, progressInterval: 0)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await engine.run(
            settings: CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me))
        #expect(result.outcome == .completed)
        #expect(result.failed == 1)
        #expect(result.errors.first?.hasPrefix("octo/slow: ") == true)
        #expect(ProcessInfo.processInfo.systemUptime - started < 15)
        #expect(allTime(store)?.totals.commits == 1)
    }

    @Test func excludedForksAreNeitherSyncedNorCountedAndStaleStagingIsSwept() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let mirror = try mirror(fixture)
        for name in ["mine", "fork"] {
            let url = try await fixture.makeRepository("mirror/octo/\(name)")
            try await fixture.commit(
                ["\(name).swift": "let a = 1\n"], in: url, author: me,
                date: "2024-05-01T10:00:00+00:00", message: name)
        }
        let owner = mirror.appendingPathComponent("octo")
        let abandoned = owner.appendingPathComponent(".gone.git.partial-\(UUID().uuidString)")
        let unrelated = owner.appendingPathComponent(".keep.git.partial-notes")
        for folder in [abandoned, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        let engine = CodeStatsEngine(
            github: FakeGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/mine", cloneURL: "/nowhere/mine.git"),
                CodeStatsRemoteRepository(
                    fullName: "octo/fork", cloneURL: "/nowhere/fork.git", isFork: true),
            ]), git: fixture.tool, store: store, progressInterval: 0)
        let result = await engine.run(
            settings: CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me))
        #expect(result.outcome == .completed)
        #expect(result.repositories == 1)
        #expect(allTime(store)?.repositories.map(\.repository) == ["octo/mine"])
        #expect(hiddenEntries(owner) == [unrelated.lastPathComponent])

        let withForks = await engine.run(
            settings: CodeStatsSettings(
                folder: mirror.path, identity: CodeStatsGitFixture.me, includeForks: true))
        #expect(withForks.repositories == 2)
        #expect(allTime(store)?.totals.commits == 2)
    }

    @Test func aRemovedMirrorFolderIsNeverRecreatedByAClone() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let demo = try await remote("demo", in: fixture)
        let mirror = fixture.root.appendingPathComponent("gone", isDirectory: true)
        await #expect(throws: (any Error).self) {
            try await fixture.tool.cloneMirror(
                from: demo.remote.path,
                to: CodeStatsRepositoryDiscovery.mirrorURL(root: mirror, fullName: "octo/demo"))
        }
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let destination = CodeStatsRepositoryDiscovery.mirrorURL(
            root: mirror, fullName: "octo/demo")
        try await fixture.tool.cloneMirror(from: demo.remote.path, to: destination)
        let head = destination.appendingPathComponent("HEAD")
        #expect(FileManager.default.fileExists(atPath: head.path))
    }

    @Test func aVanishedDriveInterruptsTheRunAndKeepsTheCache() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let one = try await remote("one", in: fixture)
        let two = try await remote("two", in: fixture)
        let drive = CodeStatsStorageEvaluator.standardized(
            fixture.root.appendingPathComponent("Drive").path)
        let mirror = try mirror(fixture, "Drive/mirror")
        let mounted = CodeStatsLocked(true)
        var probe = CodeStatsFileProbe.live
        probe.volume = { path in
            path.hasPrefix(drive) ? CodeStatsVolume(name: "Drive", mountPoint: drive) : nil
        }
        probe.isMounted = { _ in mounted.update { $0 } }
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        let previous = [
            CodeStatsReportBuilder.build(
                commits: [], range: .all, today: Date(), calendar: .current)
        ]
        try store.saveReports(previous)
        let engine = CodeStatsEngine(
            github: FakeGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/one", cloneURL: one.remote.path),
                CodeStatsRemoteRepository(fullName: "octo/two", cloneURL: two.remote.path),
            ]), git: fixture.tool, store: store, probe: probe, syncLimit: 1, analysisLimit: 1,
            progressInterval: 0)

        let result = await engine.run(
            settings: CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me)
        ) { event in
            if event.phase == .analyzing, event.completed >= 1 { mounted.update { $0 = false } }
        }
        #expect(result.outcome == .volumeDisconnected(volumeName: "Drive"))
        #expect(result.outcome.isInterrupted)
        #expect(result.failed == 0)
        #expect(store.loadReports() == previous)
        #expect(Array(store.loadCaches().keys) == ["octo/one"])
    }

    @Test func anAbsentVolumeIsReportedWithoutCreatingTheFolder() async throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let name = "EdithCodeStatsAbsent-\(UUID().uuidString)"
        let engine = CodeStatsEngine(
            github: FakeGitHub(listing: []), git: fixture.tool,
            store: CodeStatsStore(root: fixture.root))
        let result = await engine.run(
            settings: CodeStatsSettings(folder: "/Volumes/\(name)/GitHub"))
        #expect(result.outcome == .volumeDisconnected(volumeName: name))
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(name)"))
        let missing = await engine.run(settings: CodeStatsSettings())
        #expect(missing.outcome == .storageUnavailable(.notConfigured))
    }
}
