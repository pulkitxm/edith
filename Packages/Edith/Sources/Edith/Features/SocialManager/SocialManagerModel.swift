import EdithKit
import Foundation
import Observation
import WebKit

struct SocialWorkspaceTab: Identifiable, Equatable {
    let id = UUID()
    var layout: HerdrLayout
    var focused: String
    var zoomed: String?

    init(account: SocialAccount) {
        layout = .pane(account.id.uuidString)
        focused = account.id.uuidString
    }
}

@MainActor @Observable
final class SocialManagerModel {
    private(set) var catalog = SocialAccountCatalog()
    private(set) var tabs: [SocialWorkspaceTab] = []
    private(set) var sessions: [UUID: SocialBrowserSession] = [:]
    var selectedTabID: UUID?
    var platformID: UUID?
    var showingAccounts = true
    var message: String?
    private(set) var busy = false
    let load = ContentLoad()
    @ObservationIgnored private let file: SocialAccountFile
    @ObservationIgnored private let sessionFactory:
        @MainActor (SocialAccount, SocialPlatform) -> SocialBrowserSession

    init(
        file: SocialAccountFile = SocialAccountFile(),
        sessionFactory:
            @escaping @MainActor (SocialAccount, SocialPlatform) -> SocialBrowserSession = {
                account, platform in
                SocialBrowserSession(
                    accountID: account.id, website: platform.website,
                    dataStore: WKWebsiteDataStore(forIdentifier: account.id))
            }
    ) {
        self.file = file
        self.sessionFactory = sessionFactory
    }

    var currentTab: SocialWorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    var selectedPlatform: SocialPlatform? { catalog.platforms.first { $0.id == platformID } }

    func start() {
        guard !load.hasContent else { return }
        let request = load.begin()
        do {
            catalog = try file.load()
            load.complete(request)
        } catch { load.fail(request, error: error) }
    }

    func platform(for account: SocialAccount) -> SocialPlatform? {
        catalog.platforms.first { $0.id == account.platformID }
    }

    func account(_ id: String) -> SocialAccount? {
        catalog.accounts.first { $0.id.uuidString == id }
    }

    func title(_ tab: SocialWorkspaceTab) -> String {
        tab.layout.panes.compactMap { account($0)?.name }.joined(separator: " + ")
    }

    func saveAccount(id: UUID? = nil, platformID: UUID, name: String, badge: String) throws
        -> SocialAccount
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        var next = catalog
        let account = SocialAccount(
            id: id ?? UUID(), platformID: platformID, name: name,
            badge: String(badge.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)))
        if let index = next.accounts.firstIndex(where: { $0.id == id }) {
            next.accounts[index] = account
        } else {
            next.accounts.append(account)
        }
        try persist(next)
        return account
    }

    func addPlatform(name: String, website: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        let platform = SocialPlatform(name: name, website: try SocialPlatform.websiteURL(website))
        var next = catalog
        next.platforms.append(platform)
        try persist(next)
        platformID = platform.id
    }

    private func persist(_ next: SocialAccountCatalog) throws {
        guard load.hasContent else { throw SocialAccountError.invalidCatalog }
        try file.save(next)
        catalog = next
        message = nil
    }

    func open(_ account: SocialAccount, beside: Bool = false, side: InsertSide = .right) {
        guard !busy, let platform = platform(for: account) else { return }
        let key = account.id.uuidString
        let target = selectedTabID
        if let existing = tabs.first(where: { $0.layout.contains(key) }) {
            if !beside || existing.id == target {
                selectedTabID = existing.id
                updateTab {
                    $0.focused = key; $0.zoomed = nil
                }
                showingAccounts = false
                return
            }
            removePane(key)
            selectedTabID = target
        }
        if sessions[account.id] == nil {
            let session = sessionFactory(account, platform)
            session.onFocus = { [weak self] in self?.focus(key) }
            sessions[account.id] = session
        }
        if beside, currentTab != nil {
            updateTab {
                $0.layout = $0.layout.inserting(.pane(key), near: $0.focused, side: side)
                $0.focused = key
                $0.zoomed = nil
            }
        } else {
            let tab = SocialWorkspaceTab(account: account)
            tabs.append(tab)
            selectedTabID = tab.id
        }
        showingAccounts = false
    }

    func select(_ tab: SocialWorkspaceTab) {
        selectedTabID = tab.id
        showingAccounts = false
    }

    func focus(_ key: String) {
        guard currentTab?.layout.contains(key) == true else { return }
        updateTab { $0.focused = key }
    }

    func toggleZoom(_ key: String) {
        updateTab {
            $0.focused = key; $0.zoomed = $0.zoomed == key ? nil : key
        }
    }

    func arrange(_ axis: SplitAxis) {
        updateTab {
            $0.layout = .stack(axis, $0.layout.panes); $0.zoomed = nil
        }
    }

    func grid() {
        updateTab { tab in
            let ids = tab.layout.panes
            let middle = (ids.count + 1) / 2
            tab.layout = .group(
                .vertical,
                [
                    .stack(.horizontal, Array(ids.prefix(middle))),
                    .stack(.horizontal, Array(ids.dropFirst(middle))),
                ])
            tab.zoomed = nil
        }
    }

    func resize(split: UUID, index: Int, change: Double) {
        updateTab { $0.layout = $0.layout.resizing(split: split, index: index, by: change) }
    }

    func equalize() { updateTab { $0.layout = $0.layout.equalized() } }

    func separate() {
        guard let tab = currentTab else { return }
        let accounts = tab.layout.panes.compactMap(account)
        tabs.removeAll { $0.id == tab.id }
        for account in accounts { tabs.append(SocialWorkspaceTab(account: account)) }
        selectedTabID = tabs.last?.id
    }

    private func updateTab(_ change: (inout SocialWorkspaceTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        change(&tabs[index])
    }

    private func removePane(_ key: String) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(key) }) else { return }
        if let layout = tabs[index].layout.removing(key) {
            tabs[index].layout = layout
            if tabs[index].focused == key { tabs[index].focused = layout.panes[0] }
            tabs[index].zoomed = nil
        } else {
            tabs.remove(at: index)
        }
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.last?.id }
        if tabs.isEmpty { showingAccounts = true }
    }

    func closeAccount(_ key: String) {
        removePane(key)
        if let id = UUID(uuidString: key) { sessions.removeValue(forKey: id)?.shutdown() }
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        for key in tab.layout.panes { closeAccount(key) }
    }

    func clearSession(_ account: SocialAccount, removingAccount: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        closeAccount(account.id.uuidString)
        let dataStore = WKWebsiteDataStore(forIdentifier: account.id)
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        do {
            if removingAccount {
                var next = catalog
                next.accounts.removeAll { $0.id == account.id }
                try persist(next)
            }
            message =
                removingAccount
                ? "Account and its browser data removed."
                : "Session cleared. Open the account to sign in again."
        } catch { message = error.localizedDescription }
    }

    func shutdown() {
        for session in sessions.values { session.shutdown() }
        sessions = [:]
        tabs = []
    }
}
