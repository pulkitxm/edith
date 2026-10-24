import EdithKit
import SwiftUI

extension SocialWorkspaceTab {
    var interactionTab: HerdrTab {
        var tab = HerdrTab(id: id.uuidString, agentID: focused)
        tab.layout = layout
        tab.focused = focused
        tab.zoomed = zoomed
        return tab
    }
}

extension SocialManagerModel: PaneWorkspaceInteractions {
    var interactionTab: HerdrTab? { showingAccounts ? nil : currentTab?.interactionTab }
    var interactionTabIDs: [String] { [interactionLibraryID] + tabs.map { $0.id.uuidString } }
    var interactionLibraryID: String { "accounts" }
    var interactionSelection: String {
        get {
            showingAccounts
                ? interactionLibraryID : selectedTabID?.uuidString ?? interactionLibraryID
        }
        set {
            if newValue == interactionLibraryID {
                showingAccounts = true
            } else if let tab = tabs.first(where: { $0.id.uuidString == newValue }) {
                select(tab)
            }
        }
    }

    func normalized(_ item: HerdrDragItem) -> HerdrDragItem {
        if case let .tab(id) = item, let tab = tabs.first(where: { $0.id.uuidString == id }),
            tab.layout.paneCount == 1
        {
            return .pane(tab.focused)
        }
        return item
    }

    func draggedPaneIDs(_ item: HerdrDragItem) -> [String] {
        switch normalized(item) {
        case .pane(let id): account(id) == nil ? [] : [id]
        case .tab(let id): tabs.first { $0.id.uuidString == id }?.layout.panes ?? []
        case .agent, .space: []
        }
    }

    func paneIdentity(_ id: String) -> WorkspacePaneIdentity? {
        guard let account = account(id), let platform = platform(for: account) else { return nil }
        return WorkspacePaneIdentity(
            title: accountTitle(account), category: platform.name, symbol: platform.symbol,
            image: avatars[account.id])
    }

    func paneIsOpen(_ id: String) -> Bool { tabs.contains { $0.layout.contains(id) } }
    func dragTitle(_ item: HerdrDragItem) -> String {
        draggedPaneIDs(item).first.flatMap { paneIdentity($0)?.title } ?? "Account"
    }

    func sidebarTarget(_ item: HerdrDragItem, at point: CGPoint, frames: [String: CGRect])
        -> HerdrDropTarget?
    {
        guard case .pane = normalized(item),
            let row = HerdrDropResolver.sidebarRow(
                at: point, ids: filteredAccounts.map { $0.id.uuidString },
                prefix: HerdrDropGeometry.agentPrefix, frames: frames)
        else { return nil }
        return .sidebarAgent(row.id, after: point.y >= row.frame.midY)
    }

    func snapCount(for item: HerdrDragItem) -> Int? {
        guard let tab = interactionTab, case let .pane(id) = normalized(item) else { return nil }
        let count = tab.layout.paneCount + (tab.layout.contains(id) ? 0 : 1)
        return count >= 2 ? count : nil
    }

    func proposedLayout(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> HerdrLayout? {
        let item = normalized(item)
        guard let tab = interactionTab, let node = draggedNode(item) else { return nil }
        if case let .tab(id) = item, id == tab.id { return nil }
        let ids = node.panes
        let base = ids.reduce(Optional(tab.layout)) { $0?.removing($1) }
        switch target {
        case let .edge(pane, side):
            guard let base, !ids.contains(pane), base.contains(pane) else { return nil }
            return base.inserting(node, near: pane, side: side)
        case let .outerEdge(side): return base?.inserting(node, atEdge: side)
        case let .center(pane):
            guard case let .pane(id) = item, id != pane, tab.layout.contains(pane) else {
                return nil
            }
            return tab.layout.contains(id)
                ? tab.layout.swapping(id, pane) : tab.layout.replacing(pane, with: id)
        case let .slot(template, index):
            guard case let .pane(id) = item else { return nil }
            var order = tab.layout.panes.filter { $0 != id }
            order.insert(id, at: min(max(0, index), order.count))
            return template.layout(order)
        default: return nil
        }
    }

    func accepts(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> Bool {
        guard !busy, !draggedPaneIDs(item).isEmpty else { return false }
        switch target {
        case .edge, .outerEdge, .center, .slot: return proposedLayout(item, target) != nil
        case let .intoTab(id):
            guard let tab = tabs.first(where: { $0.id.uuidString == id }) else { return false }
            if case let .tab(source) = item { return source != id }
            return draggedPaneIDs(item).contains { !tab.layout.contains($0) }
        case .tabBar, .newTab: return true
        case .window: return draggedPaneIDs(item).count == 1
        case let .sidebarAgent(id, _):
            guard case let .pane(source) = normalized(item), let account = account(source),
                let target = self.account(id)
            else { return false }
            return source != id && account.profileID == target.profileID
        case .sidebarSpace: return false
        }
    }

    func drop(_ item: HerdrDragItem, on target: HerdrDropTarget) {
        guard accepts(item, target) else { return }
        let normalized = normalized(item)
        switch target {
        case .edge, .outerEdge, .center, .slot:
            guard let tab = currentTab, let layout = proposedLayout(item, target) else { return }
            let ids = draggedPaneIDs(item)
            let displaced: String? = {
                guard case let .center(id) = target,
                    !ids.contains(where: { tab.layout.contains($0) })
                else { return nil }
                return id
            }()
            for id in ids {
                if let account = account(id) { ensureBrowser(account) }
                if !tab.layout.contains(id) { removePane(id) }
                SocialWorkspaceWindow.reattach(id, to: self)
            }
            var updated = tab
            updated.layout = layout
            updated.focused = ids.first ?? tab.focused
            updated.zoomed = nil
            modifyTabs { tabs in
                if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                    tabs[index] = updated
                } else {
                    tabs.append(updated)
                }
            }
            select(updated)
            if let displaced, let account = account(displaced) {
                openInNewTab(account)
                select(updated)
            }
        case let .intoTab(id):
            guard let target = tabs.first(where: { $0.id.uuidString == id }),
                let node = draggedNode(normalized)
            else { return }
            let ids = node.panes
            for id in ids {
                if let account = account(id) { ensureBrowser(account); removePane(id) }
                SocialWorkspaceWindow.reattach(id, to: self)
            }
            select(target)
            updateTab {
                $0.layout = $0.layout.inserting(node, near: $0.focused, side: .right)
                $0.focused = ids[0]
                $0.zoomed = nil
            }
            activateFocusedBrowser()
        case let .tabBar(index): insertTab(item, at: index)
        case .newTab: insertTab(item, at: tabs.count)
        case let .sidebarAgent(id, after):
            guard case let .pane(source) = normalized else { return }
            var next = catalog
            guard let sourceIndex = next.accounts.firstIndex(where: { $0.id.uuidString == source })
            else { return }
            let moved = next.accounts.remove(at: sourceIndex)
            guard let targetIndex = next.accounts.firstIndex(where: { $0.id.uuidString == id })
            else { return }
            next.accounts.insert(moved, at: targetIndex + (after ? 1 : 0))
            do { try persist(next) } catch { message = error.localizedDescription }
        case .window, .sidebarSpace: break
        }
    }

    private func draggedNode(_ item: HerdrDragItem) -> HerdrLayout? {
        switch item {
        case let .pane(id): return account(id) == nil ? nil : .pane(id)
        case let .tab(id): return tabs.first { $0.id.uuidString == id }?.layout
        case .agent, .space: return nil
        }
    }

    private func insertTab(_ item: HerdrDragItem, at index: Int) {
        if case let .tab(id) = item, let tab = tabs.first(where: { $0.id.uuidString == id }) {
            let source = tabs.firstIndex { $0.id == tab.id } ?? 0
            modifyTabs {
                $0.removeAll { $0.id == tab.id }
                $0.insert(tab, at: min(max(0, index - (source < index ? 1 : 0)), $0.count))
            }
            select(tab)
        } else if case let .pane(id) = normalized(item), let account = account(id) {
            removePane(id)
            open(account)
            guard let tab = currentTab else { return }
            modifyTabs {
                $0.removeAll { $0.id == tab.id }
                $0.insert(tab, at: min(max(0, index), $0.count))
            }
        }
    }
}
