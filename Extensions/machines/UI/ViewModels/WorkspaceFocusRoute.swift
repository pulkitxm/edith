import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum WorkspaceFocusRoute {
    static func value(_ layout: WorkspaceLayout) -> String {
        guard let pane = focusedPane(layout) else { return "" }
        guard let tab = selectedTab(in: pane) else { return pane.id.uuidString }
        return join(pane.id, tab.id)
    }

    static func accepts(_ raw: String, layout: WorkspaceLayout) -> Bool {
        if raw.isEmpty { return true }
        guard let target = target(raw), let pane = layout.root.pane(target.pane) else {
            return false
        }
        return pane.tabs.contains { $0.id == target.tab }
    }

    @discardableResult
    static func apply(_ raw: String, to layout: inout WorkspaceLayout) -> Bool {
        guard let target = target(raw),
            layout.root.pane(target.pane)?.tabs.contains(where: { $0.id == target.tab }) == true
        else { return false }
        layout.focused = target.pane
        layout.root.updatePane(target.pane) { $0.selected = target.tab }
        return true
    }

    static func spaceValue(tabID: UUID, layout: WorkspaceLayout) -> String {
        let focus = value(layout)
        guard !focus.isEmpty else { return tabID.uuidString }
        return tabID.uuidString + "~" + focus
    }

    static func decodeSpace(_ raw: String) -> (tabID: UUID, focus: String)? {
        let pieces = raw.components(separatedBy: "~")
        guard pieces.count == 3, let tabID = UUID(uuidString: pieces[0]),
            target(pieces[1] + "~" + pieces[2]) != nil
        else { return nil }
        return (tabID, pieces[1] + "~" + pieces[2])
    }

    private static func focusedPane(_ layout: WorkspaceLayout) -> PaneNode? {
        layout.root.pane(layout.focused) ?? layout.root.panes.first
    }

    private static func selectedTab(in pane: PaneNode) -> PaneTab? {
        pane.tabs.first { $0.id == pane.selected } ?? pane.tabs.first
    }

    private static func join(_ pane: UUID, _ tab: UUID) -> String {
        pane.uuidString + "~" + tab.uuidString
    }

    private static func target(_ raw: String) -> (pane: UUID, tab: UUID)? {
        let pieces = raw.components(separatedBy: "~")
        guard pieces.count == 2, let pane = UUID(uuidString: pieces[0]),
            let tab = UUID(uuidString: pieces[1])
        else { return nil }
        return (pane, tab)
    }
}
