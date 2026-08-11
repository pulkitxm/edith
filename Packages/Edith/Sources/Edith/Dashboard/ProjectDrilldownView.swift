import AppKit
import EdithKit
import SwiftUI

struct ProjNode: Identifiable {
    enum Kind {
        case repository, folder, worktree, chat, more
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
    let repositoryURL: String?
    let badge: Int
    var children: [ProjNode]?
}

enum ProjColumns {
    static let project: CGFloat = 300
    static let tokens: CGFloat = 96
    static let cost: CGFloat = 82
    static let share: CGFloat = 58
    static let days: CGFloat = 44
    static let dur: CGFloat = 76
    static let last: CGFloat = 64
}

struct ProjectDrilldownView: View {
    @ObservedObject var model: DashboardModel
    let dark: Bool
    var blur = false
    var blurTokens = false

    private static let chatsPerGroup = 20
    private static let rowHeight: CGFloat = 27
    private static let minTableHeight: CGFloat = 520
    private static let maxTableHeight: CGFloat = 760

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(10)) {
                toggleButton
                if model.projListOpen {
                    SearchField(
                        placeholder: "Filter repositories, folders, worktrees, chats…",
                        text: $model.projQuery, compact: true
                    )
                    .frame(maxWidth: UIScale.pt(260))
                }
                Spacer(minLength: 0)
            }
            if model.projListOpen {
                VStack(spacing: UIScale.pt(0)) {
                    headerRow
                    Divider().opacity(0.4)
                    ScrollView {
                        LazyVStack(spacing: UIScale.pt(0)) {
                            ForEach(flatRows, id: \.node.id) { row in
                                ProjectRow(
                                    node: row.node, depth: row.depth, dark: dark, blur: blur,
                                    blurTokens: blurTokens,
                                    expanded: model.projExpanded.contains(row.node.id),
                                    onToggle: { toggleExpand(row.node.id) },
                                    onCopy: copyToPasteboard)
                                Divider().opacity(0.12)
                            }
                            if nodes.isEmpty {
                                Text("No projects match “\(model.projQuery)”")
                                    .font(.system(size: UIScale.pt(11)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                    .padding(UIScale.pt(12))
                            }
                        }
                    }
                }
                .frame(height: tableHeight)
            }
        }
    }

    private var toggleButton: some View {
        Button {
            model.projListOpen.toggle()
        } label: {
            HStack(spacing: UIScale.pt(4)) {
                Image(systemName: model.projListOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: UIScale.pt(8), weight: .semibold))
                Text(
                    "\(model.projListOpen ? "Hide" : "Show") repositories (\(model.projectTree.count))"
                )
                .font(DashSkin.mono(11))
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var headerRow: some View {
        HStack(spacing: UIScale.pt(0)) {
            headerCell("Repository", .name, width: ProjColumns.project)
            headerCell("Tokens", .tokens, width: ProjColumns.tokens)
            headerCell("Cost", .cost, width: ProjColumns.cost)
            headerCell("% share", .share, width: ProjColumns.share)
            headerCell("Days", .days, width: ProjColumns.days)
            headerCell("Time spent", .dur, width: ProjColumns.dur)
            headerCell("Last used", .lastActive, width: ProjColumns.last)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(6))
    }

    @ViewBuilder private func headerCell(_ title: String, _ key: ProjSortKey, width: CGFloat?)
        -> some View
    {
        Button {
            sortBy(key)
        } label: {
            HStack(spacing: UIScale.pt(3)) {
                Text(title).font(.system(size: UIScale.pt(11), weight: .medium))
                if model.projSortKey == key {
                    Image(systemName: model.projSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: UIScale.pt(7), weight: .bold))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func sortBy(_ key: ProjSortKey) {
        if model.projSortKey == key {
            model.projSortAscending.toggle()
        } else {
            model.projSortKey = key
            model.projSortAscending = key == .name
        }
    }

    private func toggleExpand(_ id: String) {
        if model.projExpanded.contains(id) {
            model.projExpanded.remove(id)
        } else {
            model.projExpanded.insert(id)
        }
    }

    private var flatRows: [(node: ProjNode, depth: Int)] {
        var out: [(ProjNode, Int)] = []
        func add(_ node: ProjNode, _ depth: Int) {
            out.append((node, depth))
            if model.projExpanded.contains(node.id), let kids = node.children {
                for kid in kids { add(kid, depth + 1) }
            }
        }
        for node in nodes { add(node, 0) }
        return out
    }

    private var tableHeight: CGFloat {
        min(
            max(CGFloat(model.projectTree.count + 1) * Self.rowHeight + 44, Self.minTableHeight),
            Self.maxTableHeight)
    }

    private var matchedTree: [ProjTreeRow] {
        let q = model.projQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.projectTree }
        return model.projectTree.filter { $0.matches(q) }
    }

    private var nodes: [ProjNode] {
        matchedTree.map { repository in
            let folders = repository.folders.map(folderNode)
            return ProjNode(
                id: repository.id, kind: .repository, label: repository.name,
                tokens: repository.tokens, cost: repository.cost, share: repository.share,
                days: repository.days, dur: repository.dur,
                lastActive: repository.lastActive, chatId: nil,
                repositoryURL: repository.repositoryURL, badge: repository.nestedCount,
                children: folders.isEmpty ? nil : folders)
        }
    }

    private func folderNode(_ folder: ProjFolder) -> ProjNode {
        var children = chatNodes(folder.chats, parent: folder.id)
        children += folder.worktrees.map { worktree in
            let chats = chatNodes(worktree.chats, parent: worktree.id)
            return ProjNode(
                id: worktree.id, kind: .worktree, label: worktree.name,
                tokens: worktree.tokens, cost: worktree.cost, share: worktree.share,
                days: worktree.days, dur: worktree.dur, lastActive: worktree.lastActive,
                chatId: nil, repositoryURL: nil, badge: worktree.chats.count,
                children: chats.isEmpty ? nil : chats)
        }
        return ProjNode(
            id: folder.id, kind: .folder, label: folder.displayName, tokens: folder.tokens,
            cost: folder.cost, share: folder.share, days: folder.days, dur: folder.dur,
            lastActive: folder.lastActive, chatId: nil, repositoryURL: nil,
            badge: folder.nestedCount,
            children: children.isEmpty ? nil : children)
    }

    private func chatNodes(_ chats: [ProjChat], parent: String) -> [ProjNode] {
        var out = chats.prefix(Self.chatsPerGroup).map { c in
            ProjNode(
                id: "\(parent)|chat:\(c.id)", kind: .chat, label: c.title, tokens: c.tokens,
                cost: c.cost, share: c.share, days: c.days, dur: c.dur, lastActive: c.lastActive,
                chatId: c.id, repositoryURL: nil, badge: 0, children: nil)
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
                    lastActive: "", chatId: nil, repositoryURL: nil, badge: 0, children: nil))
        }
        return out
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ProjectRow: View {
    let node: ProjNode
    let depth: Int
    let dark: Bool
    let blur: Bool
    let blurTokens: Bool
    let expanded: Bool
    let onToggle: () -> Void
    let onCopy: (String) -> Void
    @State private var hovering = false

    private var hasChildren: Bool { node.children?.isEmpty == false }

    var body: some View {
        content
            .padding(.horizontal, UIScale.pt(8))
            .frame(height: UIScale.pt(27))
            .background(hovering ? DashSkin.inkFaint(dark).opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if hasChildren { onToggle() } }
    }

    @ViewBuilder private var content: some View {
        let row = HStack(spacing: UIScale.pt(0)) {
            nameColumn
            num(DashFmt.tokensFull(node.tokens), width: ProjColumns.tokens, blurWhen: blurTokens)
            num(DashFmt.usdLong(node.cost), width: ProjColumns.cost, blurWhen: blur)
            num(DashFmt.pct(node.share), width: ProjColumns.share)
            num("\(node.days)", width: ProjColumns.days)
            num(DashFmt.duration(node.dur), width: ProjColumns.dur)
            num(
                node.lastActive.isEmpty ? "-" : DashFmt.dateShort(node.lastActive),
                width: ProjColumns.last)
            Spacer(minLength: 0)
        }
        if let chatId = node.chatId, !chatId.isEmpty {
            row.contextMenu { Button("Copy chat ID") { onCopy(chatId) } }
        } else if let repositoryURL {
            row.contextMenu {
                Button("Open repository") { NSWorkspace.shared.open(repositoryURL) }
                Button("Copy repository link") { onCopy(repositoryURL.absoluteString) }
            }
        } else {
            row
        }
    }

    private var nameColumn: some View {
        HStack(spacing: UIScale.pt(5)) {
            if hasChildren {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: UIScale.pt(8), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(10))
            } else {
                Color.clear.frame(width: UIScale.pt(10))
            }
            nodeLabel
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .foregroundStyle(tint)
        .frame(width: ProjColumns.project, alignment: .leading)
    }

    @ViewBuilder private var nodeLabel: some View {
        if let repositoryURL {
            Button {
                NSWorkspace.shared.open(repositoryURL)
            } label: {
                HStack(spacing: UIScale.pt(5)) {
                    iconView
                    rowLabel
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
        } else {
            iconView
            rowLabel
        }
    }

    private var rowLabel: some View {
        Text(node.label).font(.system(size: UIScale.pt(11))).lineLimit(1).truncationMode(.tail)
    }

    private var repositoryURL: URL? {
        guard let raw = node.repositoryURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    @ViewBuilder private var iconView: some View {
        let img = ZStack(alignment: .topTrailing) {
            Image(systemName: icon).font(.system(size: UIScale.pt(10)))
            if node.badge > 0 {
                Text(node.badge > 99 ? "99+" : "\(node.badge)")
                    .font(.system(size: UIScale.pt(7), weight: .semibold))
                    .offset(x: 7, y: -4)
            }
        }
        .frame(width: UIScale.pt(16), height: UIScale.pt(14), alignment: .leading)
        if let chatId = node.chatId, !chatId.isEmpty {
            Button {
                onCopy(chatId)
            } label: {
                img
            }.buttonStyle(.plain).pointerCursor()
        } else {
            img
        }
    }

    private func num(_ text: String, width: CGFloat, blurWhen: Bool = false) -> some View {
        Text(text)
            .font(DashSkin.mono(11))
            .lineLimit(1)
            .foregroundStyle(tint)
            .frame(width: width, alignment: .leading)
            .presenterBlur(blurWhen)
    }

    private var tint: Color {
        switch node.kind {
        case .repository, .folder, .worktree: return DashSkin.ink(dark)
        case .chat: return DashSkin.inkSoft(dark)
        case .more: return DashSkin.inkFaint(dark)
        }
    }

    private var icon: String {
        switch node.kind {
        case .repository: return "shippingbox"
        case .folder: return "folder"
        case .worktree: return "arrow.triangle.branch"
        case .chat, .more: return "message"
        }
    }
}
