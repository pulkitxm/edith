import Foundation
import EdithCore
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct GitHubBrowserModelTests {
    @Test func routesAddressesAndPreservesTheFinalClosedTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubSessionStore(file: root.appendingPathComponent("session.json"))
        let model = GitHubBrowserModel(store: store)
        let originalID = try #require(model.session.selectedTabID)

        model.updateAddressDraft("acme/orbit/blob/main/README.md#L8")
        model.submitAddress()
        #expect(
            model.currentRoute?.url.absoluteString
                == "https://github.com/acme/orbit/blob/main/README.md#L8")

        model.close(originalID)
        #expect(model.session.tabs.count == 1)
        #expect(model.session.recentlyClosed.map(\.tab.id) == [originalID])
        model.reopenLastClosed()
        #expect(model.session.tabs.count == 2)
        #expect(model.session.selectedTabID == originalID)

        model.updateAddressDraft("not a valid URL")
        model.submitAddress()
        #expect(model.addressError != nil)
        await model.waitForPendingSave()
        let restored = try await store.restore()
        #expect(restored == model.session)
    }

    @Test func readyRepositoryLoadsAndReloadFetchesAgain() async throws {
        let fixture = GitHubResourceFixture()
        let context = try await modelContext(route: repositoryRoute("first"), fixture: fixture)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        await fixture.release(0, resource: repositoryResource("first"))
        await context.model.waitForResourceLoad()

        #expect(context.model.resource == repositoryResource("first"))
        #expect(context.model.resourceState == .content)

        context.model.reload()
        await fixture.waitUntilStarted(2)
        await fixture.release(1, resource: repositoryResource("first"))
        await context.model.waitForResourceLoad()
        #expect(await fixture.requestCount() == 2)
    }

    @Test func staleCompletionCannotReplaceNewerNavigation() async throws {
        let fixture = GitHubResourceFixture()
        let context = try await modelContext(route: repositoryRoute("first"), fixture: fixture)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        context.model.navigate(to: repositoryRoute("second"))
        await fixture.waitUntilStarted(2)

        await fixture.release(1, resource: repositoryResource("second"))
        await context.model.waitForResourceLoad()
        #expect(context.model.resource == repositoryResource("second"))

        await fixture.release(0, resource: repositoryResource("first"))
        await Task.yield()
        #expect(context.model.resource == repositoryResource("second"))
    }

    @Test func cachedResourceStaysVisibleWhileRefreshIsPending() async throws {
        let fixture = GitHubResourceFixture()
        let cached = repositoryResource("cached")
        let context = try await modelContext(
            route: repositoryRoute("first"), fixture: fixture, cached: cached)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        await Task.yield()
        #expect(context.model.resource == cached)
        #expect(context.model.resourceState == .refreshing)

        await fixture.release(0, resource: repositoryResource("first"))
        await context.model.waitForResourceLoad()
        #expect(context.model.resource == repositoryResource("first"))
        #expect(context.model.resourceState == .content)
    }

    @Test func deinitializationCancelsAnActiveResourceLoad() async throws {
        let fixture = GitHubCancellationFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubSessionStore(file: root.appendingPathComponent("session.json"))
        let route = repositoryRoute("first")
        let tab = GitHubBrowserTab(
            entry: GitHubBrowserHistoryEntry(route: route), title: route.url.lastPathComponent)
        try await store.save(GitHubBrowserSession(tabs: [tab], selectedTabID: tab.id))
        var model: GitHubBrowserModel? = GitHubBrowserModel(
            store: store, checkReadiness: { .ready("Signed in") },
            readCachedResource: { _ in nil },
            loadResource: { try await fixture.load($0) })
        weak let releasedModel = model

        await model?.start()
        await fixture.waitUntilStarted()
        model = nil

        for _ in 0..<100 where !(await fixture.wasCancelled()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedModel == nil)
        #expect(await fixture.wasCancelled())
    }

    @Test func lineSelectionNavigationKeepsTheLoadedFileWithoutRefetching() async throws {
        let fixture = GitHubResourceFixture()
        let route = fileRoute(lines: nil)
        let context = try await modelContext(route: route, fixture: fixture)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        await fixture.release(0, resource: fileResource())
        await context.model.waitForResourceLoad()

        context.model.navigate(to: fileRoute(lines: .range(4...9)))
        await Task.yield()

        #expect(await fixture.requestCount() == 1)
        #expect(context.model.resource == fileResource())
        #expect(context.model.resourceState == .content)
        #expect(context.model.currentRoute?.url.fragment == "L4-L9")
    }

    @Test func lineSelectionNavigationPreservesPendingFileRefresh() async throws {
        let fixture = GitHubResourceFixture()
        let cached = fileResource(sha: "cached", text: "let cached = true\n")
        let context = try await modelContext(
            route: fileRoute(lines: nil), fixture: fixture, cached: cached)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        #expect(context.model.resource == cached)
        #expect(context.model.resourceState == .refreshing)

        context.model.navigate(to: fileRoute(lines: .range(40...44)))
        #expect(await fixture.requestCount() == 1)
        #expect(context.model.resourceState == .refreshing)

        let fresh = fileResource(sha: "fresh", text: "let fresh = true\n")
        await fixture.release(0, resource: fresh)
        await context.model.waitForResourceLoad()

        #expect(context.model.resource == fresh)
        #expect(context.model.resourceState == .content)
        #expect(context.model.loadedRoute?.url.fragment == "L40-L44")
    }

    @Test func resolvedSlashReferenceLineSelectionDoesNotRefetch() async throws {
        let fixture = GitHubResourceFixture()
        let unresolved = try #require(
            GitHubRoute(
                url: URL(
                    string:
                        "https://github.com/acme/orbit/blob/feature/navigation/Sources/Orbit.swift")!
            ))
        let context = try await modelContext(route: unresolved, fixture: fixture)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        let snapshot = GitHubRepositoryResource.file(
            GitHubFileSnapshot(
                repository: GitHubRepositoryPath(owner: "acme", name: "orbit")!,
                revision: "feature/navigation", path: "Sources/Orbit.swift", sha: "abc123",
                size: 19, text: "let orbit = true\n", downloadURL: nil, presentation: .text))
        await fixture.release(0, resource: snapshot)
        await context.model.waitForResourceLoad()

        let location = try #require(
            GitHubResolvedContentPath(
                revision: "feature/navigation", path: ["Sources", "Orbit.swift"]))
        let selected = GitHubRoute(
            host: .github,
            resource: .content(
                repository: GitHubRepositoryPath(owner: "acme", name: "orbit")!, kind: .blob,
                revisionPath: ["feature", "navigation", "Sources", "Orbit.swift"],
                view: .automatic, lines: .range(4...9)),
            resolvedContentPath: location)
        context.model.navigate(to: selected)
        await Task.yield()

        #expect(await fixture.requestCount() == 1)
        #expect(context.model.resource == snapshot)
        #expect(context.model.currentRoute?.url.fragment == "L4-L9")
    }

    @Test func distinctResolvedBoundariesWithTheSameURLRefetch() async throws {
        let fixture = GitHubResourceFixture()
        let repository = GitHubRepositoryPath(owner: "acme", name: "orbit")!
        let first = resolvedFileRoute(
            repository: repository, revision: "release", path: ["v2", "Guide.md"])
        let second = resolvedFileRoute(
            repository: repository, revision: "release/v2", path: ["Guide.md"])
        let context = try await modelContext(route: first, fixture: fixture)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        let firstResource = GitHubRepositoryResource.file(
            GitHubFileSnapshot(
                repository: repository, revision: "release", path: "v2/Guide.md", sha: "one",
                size: 4, text: "one\n", downloadURL: nil, presentation: .text))
        await fixture.release(0, resource: firstResource)
        await context.model.waitForResourceLoad()

        context.model.navigate(to: second)
        for _ in 0..<100 where await fixture.requestCount() < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.url == second.url)
        #expect(await fixture.requestCount() == 2)
        let secondResource = GitHubRepositoryResource.file(
            GitHubFileSnapshot(
                repository: repository, revision: "release/v2", path: "Guide.md", sha: "two",
                size: 4, text: "two\n", downloadURL: nil, presentation: .text))
        await fixture.release(1, resource: secondResource)
        await context.model.waitForResourceLoad()
        #expect(context.model.resource == secondResource)
    }

    @Test func newTabNavigationStaysInTheBackgroundWithoutReloading() async throws {
        let fixture = GitHubResourceFixture()
        let context = try await modelContext(route: repositoryRoute("first"), fixture: fixture)
        defer { try? FileManager.default.removeItem(at: context.root) }

        await context.model.start()
        await fixture.waitUntilStarted(1)
        await fixture.release(0, resource: repositoryResource("first"))
        await context.model.waitForResourceLoad()
        let selectedTabID = context.model.session.selectedTabID

        let destination = repositoryRoute("second")
        context.model.navigate(to: destination, inNewTab: true)
        await Task.yield()

        #expect(context.model.session.selectedTabID == selectedTabID)
        #expect(context.model.session.tabs.count == 2)
        #expect(context.model.session.tabs.last?.currentEntry.route == destination)
        #expect(await fixture.requestCount() == 1)
    }

    private func modelContext(
        route: GitHubRoute, fixture: GitHubResourceFixture,
        cached: GitHubRepositoryResource? = nil
    ) async throws -> (model: GitHubBrowserModel, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = GitHubSessionStore(file: root.appendingPathComponent("session.json"))
        let tab = GitHubBrowserTab(
            entry: GitHubBrowserHistoryEntry(route: route), title: route.url.lastPathComponent)
        try await store.save(GitHubBrowserSession(tabs: [tab], selectedTabID: tab.id))
        let model = GitHubBrowserModel(
            store: store, checkReadiness: { .ready("Signed in") },
            readCachedResource: { _ in cached },
            loadResource: { try await fixture.load($0) })
        return (model, root)
    }

    private func repositoryRoute(_ name: String) -> GitHubRoute {
        GitHubRoute(
            host: .github,
            resource: .repository(GitHubRepositoryPath(owner: "acme", name: name)!))
    }

    private func repositoryResource(_ name: String) -> GitHubRepositoryResource {
        let repository = GitHubRepositoryPath(owner: "acme", name: name)!
        return .repository(
            GitHubRepositoryOverview(
                repository: repository, description: name, isPrivate: false, isFork: false,
                isArchived: false, defaultBranch: "main", stars: 1, forks: 2, openIssues: 3,
                language: "Swift", license: "MIT", topics: [], updatedAt: nil,
                url: URL(string: "https://github.com/acme/\(name)")!, branches: [],
                latestCommit: nil, entries: []))
    }

    private func fileRoute(lines: GitHubLineSelection?) -> GitHubRoute {
        GitHubRoute(
            host: .github,
            resource: .content(
                repository: GitHubRepositoryPath(owner: "acme", name: "orbit")!, kind: .blob,
                revisionPath: ["main", "Sources", "Orbit.swift"], view: .automatic,
                lines: lines))
    }

    private func resolvedFileRoute(
        repository: GitHubRepositoryPath, revision: String, path: [String]
    ) -> GitHubRoute {
        GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: revision.split(separator: "/").map(String.init) + path,
                view: .automatic, lines: nil),
            resolvedContentPath: GitHubResolvedContentPath(revision: revision, path: path))
    }

    private func fileResource(
        sha: String = "abc123", text: String = "let orbit = true\n"
    ) -> GitHubRepositoryResource {
        .file(
            GitHubFileSnapshot(
                repository: GitHubRepositoryPath(owner: "acme", name: "orbit")!, revision: "main",
                path: "Sources/Orbit.swift", sha: sha, size: text.utf8.count, text: text,
                downloadURL: nil, presentation: .text))
    }
}

private actor GitHubResourceFixture {
    private var started = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var loadWaiters: [Int: CheckedContinuation<GitHubRepositoryResource, Error>] = [:]

    func load(_ route: GitHubRoute) async throws -> GitHubRepositoryResource {
        let index = started
        started += 1
        let ready = startWaiters.filter { started >= $0.0 }
        startWaiters.removeAll { started >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { loadWaiters[index] = $0 }
    }

    func waitUntilStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(_ index: Int, resource: GitHubRepositoryResource) {
        loadWaiters.removeValue(forKey: index)?.resume(returning: resource)
    }

    func requestCount() -> Int { started }
}

private actor GitHubCancellationFixture {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load(_ route: GitHubRoute) async throws -> GitHubRepositoryResource {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(30))
            throw GitHubRepositoryLoadError.commandFailed("Expected cancellation.")
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func wasCancelled() -> Bool { cancelled }
}
