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
