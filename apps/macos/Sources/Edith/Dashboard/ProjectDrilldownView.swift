import AppKit
import EdithKit
import SwiftUI

struct ProjNode: Identifiable {
    enum Kind {
        case project, worktree, chat, more
    }
    let id: String
    let kind: Kind
    let label: String
    let tokens: Double
    let cost: Double
    let share: Double
    let days: Int
    let dur: Double
    let lastActive: String
    let chatId: String?
    let badge: Int
    var children: [ProjNode]?
}

struct ProjectDrilldownView: View {
    @ObservedObject var model: DashboardModel
    let dark: Bool
    var blur = false
    @State private var sortOrder = [KeyPathComparator(\ProjNode.cost, order: .reverse)]

    private static let chatsPerGroup = 20
    private static let rowHeight: CGFloat = 24
    private static let maxTableHeight: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleButton
            if model.projListOpen {
                projectTable
            }
        }
    }

    private var toggleButton: some View {
        Button {
            model.projListOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.projListOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                Text(
                    "\(model.projListOpen ? "Hide" : "Show") projects (\(model.projectTree.count))"
                )
                .font(DashSkin.mono(11))
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var projectTable: some View {
        rawTable
            .tableStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .frame(height: tableHeight)
            .onChange(of: sortOrder) { _, order in
                guard let c = order.first else { return }
                let key = Self.sortKey(for: c.keyPath)
                let ascending = c.order == .forward
                if model.projSortKey != key { model.projSortKey = key }
                if model.projSortAscending != ascending { model.projSortAscending = ascending }
            }
            .onChange(of: model.projSortKey) { _, _ in syncSortOrder() }
            .onChange(of: model.projSortAscending) { _, _ in syncSortOrder() }
            .onAppear { syncSortOrder() }
    }

    private var rawTable: some View {
        Table(nodes, children: \ProjNode.children, sortOrder: $sortOrder) {
            SwiftUI.TableColumn("Project", value: \ProjNode.label) { (node: ProjNode) in
                nameCell(node)
            }
            .width(min: 200)
            SwiftUI.TableColumn("Tokens", value: \ProjNode.tokens) { (node: ProjNode) in
                numCell(DashFmt.tokensFull(node.tokens), node, blurred: true)
            }
            .width(min: 70, ideal: 95)
            SwiftUI.TableColumn("Cost", value: \ProjNode.cost) { (node: ProjNode) in
                numCell(DashFmt.usdLong(node.cost), node, blurred: true)
            }
            .width(min: 60, ideal: 85)
            SwiftUI.TableColumn("% share", value: \ProjNode.share) { (node: ProjNode) in
                numCell(DashFmt.pct(node.share), node)
            }
            .width(min: 45, ideal: 55)
            SwiftUI.TableColumn("Days", value: \ProjNode.days) { (node: ProjNode) in
                numCell("\(node.days)", node)
            }
            .width(min: 35, ideal: 45)
            SwiftUI.TableColumn("Time spent", value: \ProjNode.dur) { (node: ProjNode) in
                numCell(DashFmt.duration(node.dur), node)
            }
            .width(min: 55, ideal: 70)
            SwiftUI.TableColumn("Last used", value: \ProjNode.lastActive) { (node: ProjNode) in
                numCell(node.lastActive.isEmpty ? "—" : DashFmt.dateShort(node.lastActive), node)
            }
            .width(min: 50, ideal: 62)
        }
    }

    private var tableHeight: CGFloat {
        min(CGFloat(model.projectTree.count + 1) * Self.rowHeight + 32, Self.maxTableHeight)
    }

    private static func sortKey(for keyPath: PartialKeyPath<ProjNode>) -> ProjSortKey {
        switch keyPath {
        case \ProjNode.label: return .name
        case \ProjNode.tokens: return .tokens
        case \ProjNode.share: return .share
        case \ProjNode.days: return .days
        case \ProjNode.dur: return .dur
        case \ProjNode.lastActive: return .lastActive
        default: return .cost
        }
    }

    private static func keyPath(for key: ProjSortKey) -> KeyPathComparator<ProjNode> {
        switch key {
        case .name: return KeyPathComparator(\ProjNode.label)
        case .tokens: return KeyPathComparator(\ProjNode.tokens)
        case .cost: return KeyPathComparator(\ProjNode.cost)
        case .share: return KeyPathComparator(\ProjNode.share)
        case .days: return KeyPathComparator(\ProjNode.days)
        case .dur: return KeyPathComparator(\ProjNode.dur)
        case .lastActive: return KeyPathComparator(\ProjNode.lastActive)
        }
    }

    private func syncSortOrder() {
        var c = Self.keyPath(for: model.projSortKey)
        c.order = model.projSortAscending ? .forward : .reverse
        if sortOrder.first != c { sortOrder = [c] }
    }

    private var nodes: [ProjNode] {
        model.projectTree.map { p in
            var kids = chatNodes(p.chats, parent: p.id)
            kids += p.worktrees.map { wt in
                let wtChats = chatNodes(wt.chats, parent: wt.id)
                return ProjNode(
                    id: wt.id, kind: .worktree, label: wt.name, tokens: wt.tokens, cost: wt.cost,
                    share: wt.share, days: wt.days, dur: wt.dur, lastActive: wt.lastActive,
                    chatId: nil, badge: wt.chats.count, children: wtChats.isEmpty ? nil : wtChats)
            }
            return ProjNode(
                id: p.id, kind: .project, label: p.name, tokens: p.tokens, cost: p.cost,
                share: p.share, days: p.days, dur: p.dur, lastActive: p.lastActive,
                chatId: nil, badge: p.nestedCount, children: kids.isEmpty ? nil : kids)
        }
    }

    private func chatNodes(_ chats: [ProjChat], parent: String) -> [ProjNode] {
        var out = chats.prefix(Self.chatsPerGroup).map { c in
            ProjNode(
                id: "\(parent)|chat:\(c.id)", kind: .chat, label: c.title, tokens: c.tokens,
                cost: c.cost, share: c.share, days: c.days, dur: c.dur, lastActive: c.lastActive,
                chatId: c.id, badge: 0, children: nil)
        }
        let rest = chats.dropFirst(Self.chatsPerGroup)
        if !rest.isEmpty {
            let days = rest.reduce(into: Set<String>()) { $0.formUnion($1.daySet) }
            out.append(
                ProjNode(
                    id: "\(parent)|more", kind: .more, label: "+\(rest.count) more chats",
                    tokens: rest.reduce(0) { $0 + $1.tokens },
                    cost: rest.reduce(0) { $0 + $1.cost },
                    share: rest.reduce(0) { $0 + $1.share },
                    days: days.count,
                    dur: rest.reduce(0) { $0 + $1.dur },
                    lastActive: "", chatId: nil, badge: 0, children: nil))
        }
        return out
    }

    private func tint(_ node: ProjNode) -> Color {
        switch node.kind {
        case .project, .worktree: return DashSkin.ink(dark)
        case .chat: return DashSkin.inkSoft(dark)
        case .more: return DashSkin.inkFaint(dark)
        }
    }

    private func icon(_ node: ProjNode) -> String {
        switch node.kind {
        case .project: return "folder"
        case .worktree: return "arrow.triangle.branch"
        case .chat, .more: return "message"
        }
    }

    @ViewBuilder private func nameCell(_ node: ProjNode) -> some View {
        let cell = HStack(spacing: 5) {
            iconView(node)
            Text(node.label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint(node))
        if let chatId = node.chatId, !chatId.isEmpty {
            cell.contextMenu {
                Button("Copy chat ID") { copyToPasteboard(chatId) }
            }
        } else {
            cell
        }
    }

    @ViewBuilder private func iconView(_ node: ProjNode) -> some View {
        let img = ZStack(alignment: .topTrailing) {
            Image(systemName: icon(node)).font(.system(size: 10))
            if node.badge > 0 {
                Text(node.badge > 99 ? "99+" : "\(node.badge)")
                    .font(.system(size: 7, weight: .semibold))
                    .offset(x: 7, y: -4)
            }
        }
        .frame(width: 16, height: 14, alignment: .leading)
        if let chatId = node.chatId, !chatId.isEmpty {
            Button {
                copyToPasteboard(chatId)
            } label: {
                img
            }
            .buttonStyle(.plain)
            .pointerCursor()
        } else {
            img
        }
    }

    private func numCell(_ text: String, _ node: ProjNode, blurred: Bool = false) -> some View {
        Text(text)
            .font(DashSkin.mono(11))
            .lineLimit(1)
            .foregroundStyle(tint(node))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .presenterBlur(blurred && blur)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
