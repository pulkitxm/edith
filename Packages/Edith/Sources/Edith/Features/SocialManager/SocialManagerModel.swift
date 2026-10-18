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
    var profileID: UUID?
    var showingAccounts = true
    var message: String?
    private(set) var busy = false
    let load = ContentLoad()
    @ObservationIgnored private let file: SocialAccountFile
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private let sessionFactory:
        @MainActor (SocialAccount, SocialPlatform, WKWebsiteDataStore?) -> SocialBrowserSession

    init(
        file: SocialAccountFile = SocialAccountFile(),
        sessionFactory:
            @escaping @MainActor (SocialAccount, SocialPlatform, WKWebsiteDataStore?) ->
            SocialBrowserSession = {
                account, platform, dataStore in
                SocialBrowserSession(
                    accountID: account.id, website: platform.website,
                    dataStore: dataStore ?? WKWebsiteDataStore(forIdentifier: account.id))
            }
    ) {
        self.file = file
        self.sessionFactory = sessionFactory
    }

    var currentTab: SocialWorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    var selectedProfile: SocialProfile? { catalog.profiles.first { $0.id == profileID } }

    func accounts(in profile: SocialProfile) -> [SocialAccount] {
        catalog.accounts(in: profile)
    }

    func profile(for account: SocialAccount) -> SocialProfile? {
        catalog.profiles.first { $0.id == account.profileID }
    }

    func accountTitle(_ account: SocialAccount) -> String {
        [profile(for: account)?.name, account.name].compactMap { $0 }.joined(separator: " / ")
    }

    @discardableResult
    func saveProfile(id: UUID? = nil, name: String, badge: String) throws -> SocialProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        let profile = SocialProfile(id: id ?? UUID(), name: name, badge: String(badge.prefix(2)))
        var next = catalog
        if let index = next.profiles.firstIndex(where: { $0.id == id }) {
            next.profiles[index] = profile
        } else {
            next.profiles.append(profile)
        }
        try persist(next)
        profileID = profile.id
        return profile
    }

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
        var titles: [String] = []
        for key in tab.layout.panes {
            if let account = account(key) { titles.append(accountTitle(account)) }
        }
        return titles.joined(separator: " + ")
    }

    func saveAccount(
        id: UUID? = nil, profileID: UUID, platformID: UUID, name: String, badge: String
    ) throws
        -> SocialAccount
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        var next = catalog
        let account = SocialAccount(
            id: id ?? UUID(), profileID: profileID, platformID: platformID, name: name,
            badge: String(badge.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)))
        if let index = next.accounts.firstIndex(where: { $0.id == id }) {
            next.accounts[index] = account
        } else {
            next.accounts.append(account)
        }
        try persist(next)
        return account
    }

    func addWebsite(profileID: UUID, name: String, website: String) throws -> SocialAccount {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        let platform = SocialPlatform(name: name, website: try SocialPlatform.websiteURL(website))
        let account = SocialAccount(
            profileID: profileID, platformID: platform.id, name: platform.name)
        var next = catalog
        next.platforms.append(platform)
        next.accounts.append(account)
        try persist(next)
        return account
    }

    private func persist(_ next: SocialAccountCatalog) throws {
        guard load.hasContent else { throw SocialAccountError.invalidCatalog }
        try file.save(next)
        catalog = next
        message = nil
    }

    func open(_ account: SocialAccount, beside: Bool = false, side: InsertSide = .right) {
        guard !busy, catalog.accounts.contains(where: { $0.id == account.id }),
            let platform = platform(for: account)
        else { return }
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
            let session = sessionFactory(account, platform, dataStores[account.id])
            dataStores[account.id] = session.dataStore
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
        await clearWebsiteData(account)
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

    func removeProfile(_ profile: SocialProfile) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for account in accounts(in: profile) { await clearWebsiteData(account) }
        do {
            var next = catalog
            next.accounts.removeAll { $0.profileID == profile.id }
            next.profiles.removeAll { $0.id == profile.id }
            try persist(next)
            if profileID == profile.id { profileID = nil }
            message = "Profile and its connected accounts removed."
        } catch { message = error.localizedDescription }
    }

    private func clearWebsiteData(_ account: SocialAccount) async {
        let dataStore =
            dataStores.removeValue(forKey: account.id)
            ?? WKWebsiteDataStore(forIdentifier: account.id)
        closeAccount(account.id.uuidString)
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
            ) { continuation.resume() }
        }
    }

    func shutdown() {
        for session in sessions.values { session.shutdown() }
        sessions = [:]
        dataStores = [:]
        tabs = []
    }
}
