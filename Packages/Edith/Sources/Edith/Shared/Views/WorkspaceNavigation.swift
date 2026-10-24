import EdithKit
import Foundation

@MainActor
protocol WorkspaceNavigation: PaneWorkspaceInteractions {
    func workspaceFocus(_ pane: String, zoomed: String?)
    func workspaceClosePane(_ pane: String)
    func workspaceCloseTab(_ tab: String)
}

extension WorkspaceNavigation {
    @discardableResult
    func cycleWorkspaceTab(backwards: Bool) -> Bool {
        let ids = interactionTabIDs
        guard ids.count > 1, let index = ids.firstIndex(of: interactionSelection) else {
            return false
        }
        interactionSelection = ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count]
        return true
    }

    func selectWorkspaceTab(number: Int) {
        let ids = interactionTabIDs
        let index = number == 9 ? ids.count - 1 : number - 1
        guard ids.indices.contains(index) else { return }
        interactionSelection = ids[index]
    }

    @discardableResult
    func closeFocusedWorkspaceItem() -> Bool {
        guard let tab = interactionTab else { return false }
        if tab.isSplit {
            workspaceClosePane(tab.focused)
        } else {
            workspaceCloseTab(tab.id)
        }
        return true
    }

    @discardableResult
    func performWorkspaceLayout(_ key: HerdrLayoutKey) -> Bool {
        guard let tab = interactionTab, tab.isSplit else { return false }
        switch key {
        case .focus(let side):
            if tab.zoomed == nil, let next = tab.layout.neighbor(of: tab.focused, toward: side) {
                workspaceFocus(next, zoomed: nil)
            }
        case .cycle(let backwards):
            guard let index = tab.agentIDs.firstIndex(of: tab.focused) else { return false }
            let ids = tab.agentIDs
            let next = ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count]
            workspaceFocus(next, zoomed: tab.zoomed == nil ? nil : next)
        case .zoom:
            workspaceFocus(tab.focused, zoomed: tab.zoomed == nil ? tab.focused : nil)
        }
        return true
    }
}

extension HerdrStore: WorkspaceNavigation {
    func workspaceClosePane(_ pane: String) { close(pane) }
    func workspaceCloseTab(_ tab: String) { closeTab(tab) }
}

extension SocialManagerModel: WorkspaceNavigation {
    func workspaceFocus(_ pane: String, zoomed: String?) {
        updateTab {
            $0.focused = pane; $0.zoomed = zoomed
        }
        activateFocusedBrowser()
    }

    func workspaceClosePane(_ pane: String) { closeAccount(pane) }
    func workspaceCloseTab(_ tab: String) {
        if let id = UUID(uuidString: tab) { closeTab(id) }
    }
}
