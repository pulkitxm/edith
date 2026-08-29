import EdithCore
import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class GitHubBrowserModel {
    private(set) var session = GitHubSessionStore.homeSession()
    private(set) var readiness: ExtensionAdapterReadiness = .loading(
        "Checking GitHub CLI authentication.")
    private(set) var refreshingReadiness = false
    var addressError: String?

    @ObservationIgnored private let store: GitHubSessionStore
    @ObservationIgnored private var changedBeforeRestore = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: GitHubSessionStore = .shared) {
        self.store = store
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
        let value =
            await ExtensionLiveAdapters.readiness(for: "github")
            ?? .unsupported("GitHub does not have a live readiness adapter.")
        guard !Task.isCancelled else { return }
        readiness = value
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
        addressError = nil
        mutate { $0.navigate(tabID: id, to: GitHubBrowserHistoryEntry(route: route)) }
    }

    func select(_ id: UUID) { mutate { $0.selectTab(id) } }

    func newTab() {
        mutate {
            $0.openTab(
                entry: GitHubBrowserHistoryEntry(
                    route: GitHubRoute(host: .github, resource: .home)),
                title: "GitHub")
        }
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
    }

    func duplicate(_ id: UUID) { mutate { $0.duplicateTab(id) } }

    func togglePinned(_ id: UUID) {
        guard let tab = session.tab(id: id) else { return }
        mutate { $0.setPinned(!tab.isPinned, tabID: id) }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate { $0.reorderTab(id, to: index + offset) }
    }

    func reopenLastClosed() { mutate { $0.reopenLastClosedTab() } }

    func goBack() { mutateSelected { $0.goBack(tabID: $1) } }
    func goForward() { mutateSelected { $0.goForward(tabID: $1) } }
    func reload() {
        mutateSelected { $0.reload(tabID: $1) }
        Task { await refreshReadiness() }
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
