import EdithKit
import Foundation
import WebKit

extension SocialManagerModel {
    var focusedAccount: SocialAccount? {
        guard !showingAccounts, let key = currentTab?.focused else { return nil }
        return account(key)
    }

    func openInNewTab(_ account: SocialAccount) {
        guard !busy else { return }
        if let tab = tabs.first(where: { $0.layout.contains(account.id.uuidString) }) {
            if tab.layout.paneCount == 1 { select(tab); return }
            removePane(account.id.uuidString)
        }
        open(account)
    }

    func activateFocusedBrowser() {
        let key = focusedAccount?.id
        DispatchQueue.main.async { [weak self] in
            guard let self, let key, self.focusedAccount?.id == key,
                let webView = self.sessions[key]?.selectedPage?.webView
            else { return }
            webView.window?.makeFirstResponder(webView)
        }
    }

    func openEmail(_ profile: SocialProfile, beside: Bool = false, side: InsertSide = .right) {
        guard !busy else { return }
        do {
            var next = catalog
            if !next.platforms.contains(where: { $0.id == SocialPlatform.gmail.id }) {
                next.platforms.append(.gmail)
            }
            if !next.accounts.contains(where: { $0.id == profile.id }) {
                next.accounts.append(
                    SocialAccount(
                        id: profile.id, profileID: profile.id, platformID: SocialPlatform.gmail.id,
                        name: profile.email ?? "Gmail"))
            }
            if next != catalog { try persist(next) }
            guard let account = account(profile.id.uuidString) else { return }
            if beside { open(account, beside: true, side: side) } else { openInNewTab(account) }
        } catch { message = error.localizedDescription }
    }

    func openAll(_ profile: SocialProfile, sideBySide: Bool) {
        guard !busy else { return }
        let accounts = accounts(in: profile)
        for (index, account) in accounts.enumerated() {
            if sideBySide && index > 0 {
                open(account, beside: true)
            } else {
                openInNewTab(account)
            }
        }
        if sideBySide && accounts.count > 3 { grid() }
    }

    func cycleTab(backwards: Bool) {
        guard !tabs.isEmpty else { return }
        if showingAccounts {
            if let tab = backwards ? tabs.last : tabs.first { select(tab) }
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = index + (backwards ? -1 : 1)
        if tabs.indices.contains(next) { select(tabs[next]) } else { showingAccounts = true }
    }

    func cyclePane(backwards: Bool) {
        guard !showingAccounts, let tab = currentTab,
            let index = tab.layout.panes.firstIndex(of: tab.focused)
        else { return }
        let ids = tab.layout.panes
        let next = (index + (backwards ? ids.count - 1 : 1)) % ids.count
        focus(ids[next])
        updateTab { $0.zoomed = nil }
        activateFocusedBrowser()
    }

    func reorderTab(_ id: UUID, before target: UUID) {
        guard id != target, tabs.contains(where: { $0.id == id }) else { return }
        modifyTabs { tabs in
            guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
            let tab = tabs.remove(at: source)
            let destination = tabs.firstIndex(where: { $0.id == target }) ?? tabs.endIndex
            tabs.insert(tab, at: destination)
        }
    }

    func shiftTab(_ id: UUID, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            tabs.indices.contains(index + offset)
        else { return }
        modifyTabs { $0.swapAt(index, index + offset) }
    }

    func moveToTab(
        _ account: SocialAccount, tabID: UUID, near: String? = nil, side: InsertSide = .right
    ) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        select(tab)
        if let near { focus(near) }
        if tab.layout.contains(account.id.uuidString) {
            guard let near, near != account.id.uuidString,
                let layout = tab.layout.removing(account.id.uuidString)
            else { return }
            updateTab {
                $0.layout = layout.inserting(.pane(account.id.uuidString), near: near, side: side)
                $0.focused = account.id.uuidString
                $0.zoomed = nil
            }
            return
        }
        open(account, beside: true, side: side)
    }

    func closeOtherTabs(_ id: UUID) {
        let ids = tabs.map(\.id)
        for other in ids where other != id { closeTab(other) }
    }

    func closeTabsAfter(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = Array(tabs.dropFirst(index + 1).map(\.id))
        for other in ids { closeTab(other) }
    }

    func reopenClosedTab() {
        guard !busy else { return }
        while let saved = takeClosedTab() {
            let accounts = saved.layout.panes.compactMap(account)
            guard !accounts.isEmpty else { continue }
            openInNewTab(accounts[0])
            for account in accounts.dropFirst() { open(account, beside: true) }
            if accounts.count == saved.layout.paneCount {
                updateTab {
                    $0.layout = saved.layout; $0.focused = saved.focused; $0.zoomed = nil
                }
            }
            return
        }
    }

    func moveAccount(_ account: SocialAccount, to profile: SocialProfile) {
        guard account.id != account.profileID, !busy else { return }
        do {
            _ = try saveAccount(
                id: account.id, profileID: profile.id, platformID: account.platformID,
                name: account.name, badge: account.badge)
        } catch { message = error.localizedDescription }
    }

    func reorderProfile(_ id: UUID, before target: UUID) {
        guard id != target, !busy else { return }
        var next = catalog
        guard let source = next.profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = next.profiles.remove(at: source)
        next.profiles.insert(
            profile,
            at: next.profiles.firstIndex(where: { $0.id == target }) ?? next.profiles.endIndex)
        do { try persist(next) } catch { message = error.localizedDescription }
    }

    func reorderAccount(_ id: UUID, before target: SocialAccount) {
        guard id != target.id, !busy else { return }
        var next = catalog
        guard let source = next.accounts.firstIndex(where: { $0.id == id }),
            next.accounts[source].profileID == target.profileID
        else { return }
        let account = next.accounts.remove(at: source)
        next.accounts.insert(
            account,
            at: next.accounts.firstIndex(where: { $0.id == target.id }) ?? next.accounts.endIndex)
        do { try persist(next) } catch { message = error.localizedDescription }
    }

    func perform(_ command: WindowWorkspaceCommand) -> Bool {
        guard load.hasContent, !busy else { return false }
        switch command {
        case .nextTab: cycleTab(backwards: false)
        case .previousTab: cycleTab(backwards: true)
        case .nextPane: cyclePane(backwards: false)
        case .previousPane: cyclePane(backwards: true)
        case .layout(let key):
            guard !showingAccounts, let tab = currentTab else { return false }
            switch key {
            case .cycle(let backwards): cyclePane(backwards: backwards)
            case .zoom: if tab.layout.paneCount > 1 { toggleZoom(tab.focused) }
            case .focus(let side):
                if let neighbor = tab.layout.neighbor(of: tab.focused, toward: side) {
                    focus(neighbor)
                    updateTab { $0.zoomed = nil }
                    activateFocusedBrowser()
                }
            }
        case .showLibrary: showingAccounts = true
        case .reopenTab: reopenClosedTab()
        case .selectTab(let index):
            if tabs.indices.contains(index) { select(tabs[index]) }
        case .closeTab:
            guard !showingAccounts, let tab = currentTab else { return false }
            if let account = focusedAccount, let session = sessions[account.id],
                session.pages.count > 1, let page = session.selectedPage
            {
                session.closePage(page)
            } else {
                closeTab(tab.id)
            }
        case .reload:
            guard let account = focusedAccount else { return false }
            sessions[account.id]?.selectedPage?.retry()
        case .focusAddress:
            guard focusedAccount != nil else { return false }
            addressFocusRequest = UUID()
        }
        return true
    }
}
