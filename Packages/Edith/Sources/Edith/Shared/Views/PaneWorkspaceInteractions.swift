import AppKit
import EdithKit
import SwiftUI

struct WorkspacePaneIdentity {
    let title: String
    let category: String
    let symbol: String
    var kind: String?
    var image: NSImage?
}

@MainActor
protocol PaneWorkspaceInteractions: AnyObject {
    var interactionTab: HerdrTab? { get }
    var interactionTabIDs: [String] { get }
    var interactionLibraryID: String { get }
    var interactionSelection: String { get set }
    var layoutAnimation: Animation? { get }
    func normalized(_ item: HerdrDragItem) -> HerdrDragItem
    func snapCount(for item: HerdrDragItem) -> Int?
    func templates(for count: Int) -> [HerdrLayoutTemplate]
    func proposedLayout(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> HerdrLayout?
    func accepts(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> Bool
    func drop(_ item: HerdrDragItem, on target: HerdrDropTarget)
    func draggedPaneIDs(_ item: HerdrDragItem) -> [String]
    func paneIdentity(_ id: String) -> WorkspacePaneIdentity?
    func paneIsOpen(_ id: String) -> Bool
    func dragTitle(_ item: HerdrDragItem) -> String
    func sidebarTarget(_ item: HerdrDragItem, at point: CGPoint, frames: [String: CGRect])
        -> HerdrDropTarget?
}

extension HerdrStore: PaneWorkspaceInteractions {
    var interactionTab: HerdrTab? { currentTab }
    var interactionTabIDs: [String] { orderedTabIDs }
    var interactionLibraryID: String { Self.boardID }
    var interactionSelection: String {
        get { selectedTab }
        set { selectedTab = newValue }
    }

    func draggedPaneIDs(_ item: HerdrDragItem) -> [String] {
        switch normalized(item) {
        case .agent(let agent): [agent.id]
        case .tab(let id): tab(id)?.agentIDs ?? []
        case .pane(let id): [id]
        case .space: []
        }
    }

    func paneIdentity(_ id: String) -> WorkspacePaneIdentity? {
        guard
            let agent = session(id)?.agent
                ?? (machineTerminals + listedAgents).first(where: { $0.id == id })
        else { return nil }
        return WorkspacePaneIdentity(
            title: agent.title, category: agent.kind, symbol: "terminal", kind: agent.kind)
    }

    func paneIsOpen(_ id: String) -> Bool { session(id) != nil }

    func dragTitle(_ item: HerdrDragItem) -> String {
        if case .space(let id) = item { return agentSpaces.first { $0.id == id }?.title ?? "Space" }
        return draggedPaneIDs(item).first.flatMap { paneIdentity($0)?.title } ?? "Agent"
    }

    func sidebarTarget(_ item: HerdrDragItem, at point: CGPoint, frames: [String: CGRect])
        -> HerdrDropTarget?
    {
        let prefix: String
        let ids: [String]
        switch item {
        case .agent:
            prefix = HerdrDropGeometry.agentPrefix
            ids = (machineTerminals + listedAgents).map(\.id)
        case .space:
            prefix = HerdrDropGeometry.spacePrefix
            ids = agentSpaces.map(\.id)
        case .tab, .pane: return nil
        }
        guard
            let row = HerdrDropResolver.sidebarRow(
                at: point, ids: ids, prefix: prefix, frames: frames)
        else { return nil }
        let after = point.y >= row.frame.midY
        if case .space = item { return .sidebarSpace(row.id, after: after) }
        return .sidebarAgent(row.id, after: after)
    }
}

struct WorkspacePaneMark: View {
    let pane: WorkspacePaneIdentity
    var size: CGFloat

    var body: some View {
        Group {
            if let kind = pane.kind {
                HerdrKindMark(kind: kind, size: size)
            } else if let image = pane.image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                Image(systemName: pane.symbol).font(.system(size: size))
            }
        }.frame(width: size, height: size)
    }
}

struct WorkspacePaneMarks: View {
    let panes: [WorkspacePaneIdentity]
    let dark: Bool
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: UIScale.pt(-3)) {
            ForEach(Array(panes.prefix(3).enumerated()), id: \.offset) { _, pane in
                WorkspacePaneMark(pane: pane, size: UIScale.pt(size))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(UIScale.pt(1.5))
                    .background(DashSkin.paper2(dark), in: Circle())
            }
        }
    }
}
