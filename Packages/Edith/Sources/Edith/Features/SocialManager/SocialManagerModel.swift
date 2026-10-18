import AppKit
import EdithKit
import Foundation
import Observation
import SwiftUI
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
    private(set) var avatars: [UUID: NSImage] = [:]
    private(set) var profileAvatars: [UUID: NSImage] = [:]
    @ObservationIgnored let avatarFiles: SocialAvatarFiles
    var selectedTabID: UUID?
    var profileID: UUID?
    var showingAccounts = true
    var message: String?
    var editingAccount: SocialAccount?
    var clearingAccount: SocialAccount?
    var removingAccount: SocialAccount?
    var addressFocusRequest = UUID()
    var animatesLayout = false {
        didSet { defaults.set(animatesLayout, forKey: "socialManager.animatesLayout") }
    }
    private(set) var savedArrangements: [HerdrSavedArrangement] = []
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var recentlyClosed: [SocialWorkspaceTab] = []
    private(set) var busy = false
    let load = ContentLoad()
    @ObservationIgnored private let file: SocialAccountFile
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private let sessionFactory:
        @MainActor (SocialAccount, SocialPlatform, WKWebsiteDataStore?) -> SocialBrowserSession

    init(
        file: SocialAccountFile = SocialAccountFile(),
        defaults: UserDefaults = SharedDefaults.store,
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
        self.defaults = defaults
        animatesLayout = defaults.bool(forKey: "socialManager.animatesLayout")
        savedArrangements =
            defaults.data(forKey: "socialManager.savedArrangements").flatMap {
                try? JSONDecoder().decode([HerdrSavedArrangement].self, from: $0)
            } ?? []
        avatarFiles = SocialAvatarFiles(
            directory: file.url.deletingLastPathComponent().appendingPathComponent("avatars"))
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
    func saveProfile(
        id: UUID? = nil, name: String, badge: String, email: String? = nil,
        pictureURL: URL? = nil, removePicture: Bool = false
    ) throws
        -> SocialProfile
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = catalog.profiles.first(where: { $0.id == id })?.avatarFilename
        let imported = try pictureURL.map { try avatarFiles.importImage($0) }
        let profile = SocialProfile(
            id: id ?? UUID(), name: name, badge: String(badge.prefix(2)),
            email: address?.isEmpty == false ? address : nil,
            avatarFilename: imported ?? (removePicture ? nil : previous))
        var next = catalog
        if let index = next.profiles.firstIndex(where: { $0.id == id }) {
            next.profiles[index] = profile
        } else {
            next.profiles.append(profile)
        }
        if let index = next.accounts.firstIndex(where: { $0.id == profile.id }) {
            next.accounts[index].name = profile.email ?? "Gmail"
        }
        do { try persist(next) } catch {
            if let imported { try? avatarFiles.remove(imported) }
            throw error
        }
        if let imported, let data = try? avatarFiles.read(imported) {
            profileAvatars[profile.id] = NSImage(data: data)
        } else if removePicture {
            profileAvatars.removeValue(forKey: profile.id)
        }
        if previous != profile.avatarFilename, let previous { try? avatarFiles.remove(previous) }
        profileID = profile.id
        return profile
    }

    func start() {
        guard !load.hasContent else { return }
        let request = load.begin()
        do {
            catalog = try file.load()
            for profile in catalog.profiles {
                if let name = profile.avatarFilename, let data = try? avatarFiles.read(name) {
                    profileAvatars[profile.id] = NSImage(data: data)
                }
            }
            for account in catalog.accounts {
                if let name = account.avatarFilename, let data = try? avatarFiles.read(name) {
                    avatars[account.id] = NSImage(data: data)
                }
            }
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
        id: UUID? = nil, profileID: UUID, platformID: UUID, name: String, badge: String,
        pictureURL: URL? = nil, removePicture: Bool = false
    ) throws
        -> SocialAccount
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SocialAccountError.emptyName }
        let previous = catalog.accounts.first(where: { $0.id == id })?.avatarFilename
        let imported = try pictureURL.map { try avatarFiles.importImage($0) }
        var next = catalog
        let account = SocialAccount(
            id: id ?? UUID(), profileID: profileID, platformID: platformID, name: name,
            badge: String(badge.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)),
            avatarFilename: imported ?? (removePicture ? nil : previous))
        if let index = next.accounts.firstIndex(where: { $0.id == id }) {
            next.accounts[index] = account
        } else {
            next.accounts.append(account)
        }
        do { try persist(next) } catch {
            if let imported { try? avatarFiles.remove(imported) }
            throw error
        }
        if let imported, let data = try? avatarFiles.read(imported) {
            avatars[account.id] = NSImage(data: data)
        } else if removePicture {
            avatars.removeValue(forKey: account.id)
        }
        if previous != account.avatarFilename, let previous { try? avatarFiles.remove(previous) }
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

    func persist(_ next: SocialAccountCatalog) throws {
        guard load.hasContent else { throw SocialAccountError.invalidCatalog }
        try file.save(next)
        catalog = next
        message = nil
    }

    func open(_ account: SocialAccount, beside: Bool = false, side: InsertSide = .right) {
        guard !busy, catalog.accounts.contains(where: { $0.id == account.id }),
            ensureBrowser(account)
        else { return }
        SocialWorkspaceWindow.reattach(account.id.uuidString, to: self)
        let key = account.id.uuidString
        let target = selectedTabID
        if let existing = tabs.first(where: { $0.layout.contains(key) }) {
            if !beside || existing.id == target {
                selectedTabID = existing.id
                updateTab {
                    $0.focused = key; $0.zoomed = nil
                }
                showingAccounts = false
                activateFocusedBrowser()
                return
            }
            removePane(key)
            selectedTabID = target
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
        activateFocusedBrowser()
    }

    @discardableResult
    func ensureBrowser(_ account: SocialAccount) -> Bool {
        guard let platform = platform(for: account) else { return false }
        if sessions[account.id] == nil {
            let session = sessionFactory(account, platform, dataStores[account.id])
            dataStores[account.id] = session.dataStore
            session.onFocus = { [weak self] in self?.focus(account.id.uuidString) }
            sessions[account.id] = session
        }
        return true
    }

    func select(_ tab: SocialWorkspaceTab) {
        selectedTabID = tab.id
        showingAccounts = false
        activateFocusedBrowser()
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

    func updateTab(_ change: (inout SocialWorkspaceTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        change(&tabs[index])
    }

    func removePane(_ key: String) {
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

    func closeAccount(_ key: String, remember: Bool = true) {
        SocialWorkspaceWindow.reattach(key, to: self)
        if remember, let account = account(key) {
            rememberClosed(SocialWorkspaceTab(account: account))
        }
        removePane(key)
        if let id = UUID(uuidString: key) { sessions.removeValue(forKey: id)?.shutdown() }
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        rememberClosed(tab)
        for key in tab.layout.panes { closeAccount(key, remember: false) }
    }

    private func rememberClosed(_ tab: SocialWorkspaceTab) {
        recentlyClosed.append(tab)
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
    }

    func takeClosedTab() -> SocialWorkspaceTab? { recentlyClosed.popLast() }

    func modifyTabs(_ change: (inout [SocialWorkspaceTab]) -> Void) { change(&tabs) }

    func modifyArrangements(_ change: (inout [HerdrSavedArrangement]) -> Void) {
        change(&savedArrangements)
        defaults.set(
            try? JSONEncoder().encode(savedArrangements), forKey: "socialManager.savedArrangements")
    }

    func importAvatar(_ account: SocialAccount, from url: URL) throws {
        guard !busy, let current = self.account(account.id.uuidString) else { return }
        _ = try saveAccount(
            id: current.id, profileID: current.profileID, platformID: current.platformID,
            name: current.name, badge: current.badge, pictureURL: url)
    }

    func importAvatar(_ profile: SocialProfile, from url: URL) throws {
        guard !busy, let current = catalog.profiles.first(where: { $0.id == profile.id }) else {
            return
        }
        let selection = profileID
        defer { profileID = selection }
        try saveProfile(
            id: current.id, name: current.name, badge: current.badge, email: current.email,
            pictureURL: url)
    }

    func removeAvatar(_ profile: SocialProfile) {
        guard !busy, let current = catalog.profiles.first(where: { $0.id == profile.id }) else {
            return
        }
        let selection = profileID
        defer { profileID = selection }
        do {
            try saveProfile(
                id: current.id, name: current.name, badge: current.badge, email: current.email,
                removePicture: true)
        } catch { message = error.localizedDescription }
    }

    func removeAvatar(_ account: SocialAccount) {
        guard !busy, let current = self.account(account.id.uuidString) else { return }
        do {
            _ = try saveAccount(
                id: current.id, profileID: current.profileID, platformID: current.platformID,
                name: current.name, badge: current.badge, removePicture: true)
        } catch { message = error.localizedDescription }
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
                avatars.removeValue(forKey: account.id)
                if let name = account.avatarFilename { try? avatarFiles.remove(name) }
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
        let removedAccounts = accounts(in: profile)
        for account in removedAccounts { await clearWebsiteData(account) }
        do {
            var next = catalog
            next.accounts.removeAll { $0.profileID == profile.id }
            next.profiles.removeAll { $0.id == profile.id }
            try persist(next)
            profileAvatars.removeValue(forKey: profile.id)
            if let name = profile.avatarFilename { try? avatarFiles.remove(name) }
            for account in removedAccounts {
                avatars.removeValue(forKey: account.id)
                if let name = account.avatarFilename { try? avatarFiles.remove(name) }
            }
            if profileID == profile.id { profileID = nil }
            message = "Profile and its connected accounts removed."
        } catch { message = error.localizedDescription }
    }

    private func clearWebsiteData(_ account: SocialAccount) async {
        let dataStore =
            dataStores.removeValue(forKey: account.id)
            ?? WKWebsiteDataStore(forIdentifier: account.id)
        closeAccount(account.id.uuidString, remember: false)
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
            ) { continuation.resume() }
        }
    }

    func shutdown() {
        SocialWorkspaceWindow.closeAll(for: self)
        for session in sessions.values { session.shutdown() }
        sessions = [:]
        dataStores = [:]
        tabs = []
    }
}
