import EdithCore
import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class GitHubBrowserModel {
    typealias CheckReadiness = @Sendable () async -> ExtensionAdapterReadiness
    typealias ReadCachedResource =
        @Sendable (GitHubRoute) async -> GitHubRepositoryResource?
    typealias LoadResource =
        @Sendable (GitHubRoute) async throws -> GitHubRepositoryResource

    private(set) var session = GitHubSessionStore.homeSession()
    private(set) var readiness: ExtensionAdapterReadiness = .loading(
        "Checking GitHub CLI authentication.")
    private(set) var refreshingReadiness = false
    private(set) var resourceState: ContentLoadingState = .loading
    private(set) var resource: GitHubRepositoryResource?
    private(set) var resourceError: GitHubRepositoryLoadError?
    private(set) var loadedRoute: GitHubRoute?
    var addressError: String?

    @ObservationIgnored private let store: GitHubSessionStore
    @ObservationIgnored private let checkReadiness: CheckReadiness
    @ObservationIgnored private let readCachedResource: ReadCachedResource
    @ObservationIgnored private let loadResource: LoadResource
    @ObservationIgnored private var changedBeforeRestore = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var resourceTask: Task<Void, Never>?
    @ObservationIgnored private var resourceGeneration = 0

    init(
        store: GitHubSessionStore = .shared,
        checkReadiness: @escaping CheckReadiness = {
            await ExtensionLiveAdapters.readiness(for: "github")
                ?? .unsupported("GitHub does not have a live readiness adapter.")
        },
        readCachedResource: @escaping ReadCachedResource = {
            GitHubRepositoryClient.shared.cachedResource(for: $0)
        },
        loadResource: @escaping LoadResource = {
            try await GitHubRepositoryClient.shared.load($0)
        }
    ) {
        self.store = store
        self.checkReadiness = checkReadiness
        self.readCachedResource = readCachedResource
        self.loadResource = loadResource
    }

    deinit {
        resourceTask?.cancel()
    }

    var selectedTab: GitHubBrowserTab? { session.selectedTab }
    var currentRoute: GitHubRoute? { selectedTab?.currentEntry.route }
    var addressDraft: String { selectedTab?.addressBarDraft ?? "" }

    func start() async {
        if !restored {
            do {
                let value = try await store.restore()
                if !changedBeforeRestore { session = value }
            } catch {
                readiness = .failed("The previous GitHub session could not be restored.")
                restored = true
                return
            }
            restored = true
        }
        await refreshReadiness()
    }

    func refreshReadiness() async {
        guard !refreshingReadiness else { return }
        refreshingReadiness = true
        defer { refreshingReadiness = false }
        let value = await checkReadiness()
        guard !Task.isCancelled else { return }
        readiness = value
        if value.canLoadGitHubContent { loadCurrentRoute() }
    }

    func updateAddressDraft(_ text: String) {
        addressError = nil
        guard let id = session.selectedTabID else { return }
        mutate { $0.updateAddressBarDraft(tabID: id, text: text) }
    }

    func submitAddress() {
        guard let route = Self.route(from: addressDraft), let id = session.selectedTabID else {
            addressError = "Enter a valid GitHub or GitHub Enterprise URL."
            return
        }
        let previousRoute = currentRoute
        addressError = nil
        mutate { $0.navigate(tabID: id, to: GitHubBrowserHistoryEntry(route: route)) }
        loadAfterNavigation(from: previousRoute)
    }

    func select(_ id: UUID) {
        mutate { $0.selectTab(id) }
        loadCurrentRoute()
    }

    func newTab() {
        mutate {
            $0.openTab(
                entry: GitHubBrowserHistoryEntry(
                    route: GitHubRoute(host: .github, resource: .home)),
                title: "GitHub")
        }
        loadCurrentRoute()
    }

    func close(_ id: UUID) {
        mutate { session in
            session.closeTab(id)
            if session.tabs.isEmpty {
                session.openTab(
                    entry: GitHubBrowserHistoryEntry(
                        route: GitHubRoute(host: .github, resource: .home)),
                    title: "GitHub")
            }
        }
        loadCurrentRoute()
    }

    func duplicate(_ id: UUID) {
        mutate { $0.duplicateTab(id) }
        loadCurrentRoute()
    }

    func togglePinned(_ id: UUID) {
        guard let tab = session.tab(id: id) else { return }
        mutate { $0.setPinned(!tab.isPinned, tabID: id) }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate { $0.reorderTab(id, to: index + offset) }
    }

    func reopenLastClosed() {
        mutate { $0.reopenLastClosedTab() }
        loadCurrentRoute()
    }

    func goBack() {
        let previousRoute = currentRoute
        mutateSelected { $0.goBack(tabID: $1) }
        loadAfterNavigation(from: previousRoute)
    }

    func goForward() {
        let previousRoute = currentRoute
        mutateSelected { $0.goForward(tabID: $1) }
        loadAfterNavigation(from: previousRoute)
    }

    func reload() {
        mutateSelected { $0.reload(tabID: $1) }
        loadCurrentRoute(ignoreCache: true)
    }

    func navigate(to route: GitHubRoute, title: String? = nil, inNewTab: Bool = false) {
        let previousRoute = currentRoute
        if inNewTab {
            mutate {
                $0.openTab(
                    entry: GitHubBrowserHistoryEntry(route: route), title: title ?? route.tabTitle)
            }
        } else if let id = session.selectedTabID {
            mutate { $0.navigate(tabID: id, to: GitHubBrowserHistoryEntry(route: route)) }
        }
        loadAfterNavigation(from: previousRoute)
    }

    func retryResourceLoad() {
        loadCurrentRoute(ignoreCache: true)
    }

    func waitForResourceLoad() async {
        await resourceTask?.value
    }

    func waitForPendingSave() async {
        await saveTask?.value
    }

    func loadCurrentRoute(ignoreCache: Bool = false) {
        resourceGeneration &+= 1
        let generation = resourceGeneration
        resourceTask?.cancel()
        guard readiness.canLoadGitHubContent, let route = currentRoute else { return }
        guard route.loadsRepositoryContent else {
            resource = nil
            loadedRoute = route
            resourceError = .unsupportedRoute(
                route.support == .opensOnGitHub
                    ? "This screen uses GitHub because it contains sensitive settings."
                    : "This screen is classified, but it is not part of repository browsing yet.")
            resourceState = .empty
            return
        }
        let retainsCurrentResource = loadedRoute == route && resource != nil
        if !retainsCurrentResource {
            resource = nil
            loadedRoute = route
        }
        resourceError = nil
        resourceState = retainsCurrentResource ? .refreshing : .loading
        resourceTask = Task { [weak self, readCachedResource, loadResource] in
            if !ignoreCache, !retainsCurrentResource,
                let cached = await readCachedResource(route)
            {
                guard !Task.isCancelled,
                    self?.publishCachedResource(
                        cached, route: route, generation: generation) == true
                else { return }
            }
            do {
                let loaded = try await loadResource(route)
                guard !Task.isCancelled else { return }
                self?.publishLoadedResource(loaded, route: route, generation: generation)
            } catch is CancellationError {
            } catch let error as GitHubRepositoryLoadError {
                guard !Task.isCancelled else { return }
                self?.publishResourceError(error, route: route, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.publishResourceError(
                    .commandFailed(error.localizedDescription), route: route,
                    generation: generation)
            }
        }
    }

    func waitForPendingSave() async {
        await saveTask?.value
    }

    private func publishCachedResource(
        _ cached: GitHubRepositoryResource, route: GitHubRoute, generation: Int
    ) -> Bool {
        guard generation == resourceGeneration, canPublishResource(requestedBy: route) else {
            return false
        }
        resource = cached
        resourceState = .refreshing
        return true
    }

    private func publishLoadedResource(
        _ loaded: GitHubRepositoryResource, route: GitHubRoute, generation: Int
    ) {
        guard generation == resourceGeneration, canPublishResource(requestedBy: route) else {
            return
        }
        resource = loaded
        loadedRoute = currentRoute
        resourceError = nil
        resourceState = .content
    }

    private func publishResourceError(
        _ error: GitHubRepositoryLoadError, route: GitHubRoute, generation: Int
    ) {
        guard generation == resourceGeneration, canPublishResource(requestedBy: route) else {
            return
        }
        resourceError = error
        resourceState = resource == nil ? error.loadingState : .content
    }

    private func loadAfterNavigation(from previousRoute: GitHubRoute?) {
        guard let route = currentRoute, previousRoute?.sharesFilePayload(with: route) == true
        else {
            loadCurrentRoute()
            return
        }
        loadedRoute = route
        if resource != nil {
            resourceError = nil
            if resourceState != .refreshing { resourceState = .content }
        }
    }

    private func canPublishResource(requestedBy route: GitHubRoute) -> Bool {
        guard let currentRoute else { return false }
        return currentRoute == route || currentRoute.sharesFilePayload(with: route)
    }

    private func mutateSelected(_ body: (inout GitHubBrowserSession, UUID) -> Void) {
        guard let id = session.selectedTabID else { return }
        mutate { body(&$0, id) }
    }

    private func mutate(_ body: (inout GitHubBrowserSession) -> Void) {
        body(&session)
        changedBeforeRestore = true
        let snapshot = session
        saveTask?.cancel()
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            try? await store.save(snapshot)
        }
    }

    private static func route(from draft: String) -> GitHubRoute? {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        let lower = value.lowercased()
        let address: String
        if lower == "github.com" || lower.hasPrefix("github.com/") {
            address = "https://\(value)"
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            address = value
        } else if value.contains("://") {
            return nil
        } else {
            address =
                "https://github.com/"
                + value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return URL(string: address).flatMap(GitHubRoute.init(url:))
    }
}

private extension ExtensionAdapterReadiness {
    var canLoadGitHubContent: Bool {
        switch self {
        case .ready, .degraded: true
        default: false
        }
    }
}

private extension GitHubRepositoryLoadError {
    var loadingState: ContentLoadingState {
        switch self {
        case .offline: .offline
        default: .error
        }
    }
}

private extension GitHubRoute {
    var loadsRepositoryContent: Bool {
        switch resource {
        case .repository:
            true
        case let .content(_, kind, revisionPath, _, _):
            !revisionPath.isEmpty && [.tree, .blob, .raw, .blame].contains(kind)
        default:
            false
        }
    }

    var tabTitle: String {
        switch resource {
        case let .repository(repository):
            repository.name
        case let .content(repository, _, revisionPath, _, _):
            revisionPath.last ?? repository.name
        default:
            "GitHub"
        }
    }

    func sharesFilePayload(with other: GitHubRoute) -> Bool {
        guard host == other.host,
            case let .content(repository, kind, revisionPath, _, _) = resource,
            case let .content(otherRepository, otherKind, otherRevisionPath, _, _) = other.resource,
            kind != .tree, otherKind != .tree
        else { return false }
        return repository == otherRepository && revisionPath == otherRevisionPath
    }
}
