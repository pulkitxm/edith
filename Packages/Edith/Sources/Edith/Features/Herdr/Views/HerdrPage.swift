import EdithKit
import SwiftUI

struct HerdrPage: View {
    @State private var store: HerdrStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.Presenter.blurAgents, store: SharedDefaults.store) private
        var presenterBlurAgents = true
    private var presenterState = PresenterState.shared

    init(store: HerdrStore = .shared) {
        _store = State(initialValue: store)
    }

    private var dark: Bool { scheme == .dark }
    private var hideAgents: Bool { presenterState.active && presenterBlurAgents }
    private var onBoard: Bool { store.selectedTab == HerdrStore.boardID }
    private var listedAgents: [HerdrAgent] {
        store.filteredAgents.isEmpty ? store.agents : store.filteredAgents
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            HStack(spacing: 0) {
                if !onBoard {
                    agentList
                    Divider().opacity(0.35)
                }
                ZStack(alignment: .topTrailing) {
                    board.opacity(onBoard ? 1 : 0)
                        .allowsHitTesting(onBoard)
                    ForEach(store.tabs) { tab in
                        HerdrSessionView(
                            store: store, tab: tab, launchEnabled: launchEnabled,
                            hideAgents: hideAgents
                        )
                        .opacity(tab.id == store.selectedTab ? 1 : 0)
                        .allowsHitTesting(tab.id == store.selectedTab)
                    }
                    if !onBoard {
                        detailToggle
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Herdr")
        .task(id: automaticActions) {
            if automaticActions {
                await store.watch()
            } else {
                store.stopWatching()
            }
        }
    }

    private var header: some View {
        PageHeader(
            "Herdr",
            trailing: {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(store.refreshing)
            },
            accessory: { filters })
    }

    private var detailToggle: some View {
        Button {
            withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                store.detailOpen.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
        }
        .buttonStyle(.plain)
        .padding(UIScale.pt(4))
        .widgetBar(
            cornerRadius: 8,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark)
        )
        .pointerCursor()
        .help(store.detailOpen ? "Hide details" : "Show details")
        .padding(.top, UIScale.pt(8))
        .padding(.trailing, UIScale.pt(8))
        .zIndex(1)
        .accessibilityLabel(store.detailOpen ? "Hide details" : "Show details")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            pillRow(
                items: store.machineChoices.map { ($0.id, $0.name) },
                isSelected: { $0 == store.machineFilter }
            ) { store.machineFilter = $0 }
            pillRow(
                items: [("all", "Any agent")] + store.kindChoices.map { ($0, $0) },
                isSelected: { store.kindIsSelected($0) },
                showsKindMark: true
            ) { store.selectKind($0) }
        }
    }

    private func pillRow(
        items: [(String, String)], isSelected: @escaping (String) -> Bool,
        showsKindMark: Bool = false,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(6)) {
                ForEach(items, id: \.0) { item in
                    let selected = isSelected(item.0)
                    Button {
                        onSelect(item.0)
                    } label: {
                        HStack(spacing: UIScale.pt(5)) {
                            if showsKindMark, item.0 != "all" {
                                HerdrKindMark(kind: item.0, size: UIScale.pt(11))
                            }
                            Text(item.1)
                                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                        }
                        .foregroundStyle(
                            selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
                        )
                        .padding(.horizontal, UIScale.pt(10))
                        .padding(.vertical, UIScale.pt(5))
                        .widgetBar(
                            cornerRadius: 8,
                            fill: selected
                                ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55),
                            stroke: selected
                                ? DashSkin.accent(dark).opacity(0.55) : DashSkin.line(dark),
                            strokeWidth: selected ? 1.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .modifier(KindPillHelp(enabled: showsKindMark))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(6)) {
                    tabButton(id: HerdrStore.boardID, title: "Board", closable: false)
                    ForEach(store.tabs) { tab in
                        tabButton(
                            id: tab.id,
                            title: hideAgents ? tab.agent.kind : tab.agent.title,
                            closable: true, agent: tab.agent)
                    }
                }
                .padding(.horizontal, PageMetrics.gutter(compact))
                .padding(.vertical, UIScale.pt(8))
            }
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
        }
        .background(DashSkin.paper2(dark).opacity(0.4))
    }

    private func tabButton(id: String, title: String, closable: Bool, agent: HerdrAgent? = nil)
        -> some View
    {
        let selected = store.selectedTab == id
        return Button {
            store.selectedTab = id
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                if let agent {
                    Circle()
                        .fill(HerdrStatusColor.color(agent.status, dark: dark))
                        .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                    HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                        .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                } else {
                    AppGlyph(.herdr, size: UIScale.pt(13), weight: .semibold)
                }
                Text(title)
                    .font(.system(size: UIScale.pt(12), weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                if let agent {
                    Button {
                        store.copyAttachCommand(for: agent)
                    } label: {
                        Image(
                            systemName: store.copiedID == agent.id ? "checkmark" : "terminal"
                        )
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(
                            store.copiedID == agent.id
                                ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                    }
                    .buttonStyle(.plain)
                    .help(store.copiedID == agent.id ? "Copied" : "Copy attach command")
                }
                if closable {
                    Button {
                        store.close(id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: UIScale.pt(9), weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(6))
            .widgetBar(
                cornerRadius: 8,
                fill: selected
                    ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55),
                stroke: selected ? DashSkin.lineStrong(dark) : DashSkin.line(dark),
                strokeWidth: selected ? 1.4 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .contextMenu { tabContextMenu(id: id, closable: closable) }
        .help(agent.map { "\($0.kind) · \($0.machineName)" } ?? "Board")
    }

    @ViewBuilder
    private func tabContextMenu(id: String, closable: Bool) -> some View {
        Button("Close Others") {
            store.closeOthers(besides: id)
        }
        .disabled(!store.canCloseOthers(besides: id))
        Button("Close to the Right") {
            store.closeToTheRight(of: id)
        }
        .disabled(!store.canCloseToTheRight(of: id))
        Button("Close to the Left") {
            store.closeToTheLeft(of: id)
        }
        .disabled(!store.canCloseToTheLeft(of: id))
        if closable {
            Divider()
            Button("Close", role: .destructive) {
                store.close(id)
            }
        }
    }

    private var board: some View {
        Group {
            if store.hosts.isEmpty, store.refreshing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.hosts.allSatisfy({ !$0.herdrPresent }) && store.agents.isEmpty {
                emptyState(
                    title: "Herdr is not installed",
                    detail:
                        "Install Herdr on this Mac or an SSH machine, then refresh. Edith looks for the herdr binary on PATH, including ~/.local/bin."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: UIScale.pt(12)) {
                        ForEach(store.columns, id: \.self) { status in
                            column(status)
                        }
                    }
                    .pageContent(compact)
                    .padding(.top, UIScale.pt(16))
                }
            }
        }
    }

    private func column(_ status: HerdrAgentStatus) -> some View {
        let cards = store.filteredAgents.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                Circle()
                    .fill(HerdrStatusColor.color(status, dark: dark))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                Text(status.title)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("\(cards.count)")
                    .font(DashSkin.mono(10, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            ScrollView {
                VStack(spacing: UIScale.pt(8)) {
                    ForEach(cards) { agent in
                        card(agent)
                    }
                    if cards.isEmpty {
                        emptyColumnSlot
                    }
                }
            }
        }
        .frame(width: UIScale.pt(compact ? 220 : 240), alignment: .topLeading)
        .frame(minHeight: UIScale.pt(220), alignment: .topLeading)
    }

    private var emptyColumnSlot: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
            .strokeBorder(
                DashSkin.line(dark),
                style: StrokeStyle(lineWidth: 1, dash: [UIScale.pt(5), UIScale.pt(4)])
            )
            .frame(height: UIScale.pt(72))
            .overlay {
                Text("No panes")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .accessibilityLabel("No panes")
    }

    private func card(_ agent: HerdrAgent) -> some View {
        let open = store.openIDs.contains(agent.id)
        return Button {
            openAgent(agent)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                HStack(spacing: UIScale.pt(6)) {
                    HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    Text(agent.kind)
                        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    Spacer(minLength: 0)
                    if open {
                        Text("Open")
                            .font(.system(size: UIScale.pt(9), weight: .semibold))
                            .foregroundStyle(DashSkin.accent(dark))
                            .padding(.horizontal, UIScale.pt(6))
                            .padding(.vertical, UIScale.pt(2))
                            .background(
                                DashSkin.accent(dark).opacity(0.12),
                                in: Capsule())
                    }
                }
                .foregroundStyle(DashSkin.inkSoft(dark))
                if hideAgents {
                    hiddenLine
                    Text(agent.machineName)
                        .font(DashSkin.mono(10))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                } else {
                    Text(agent.title)
                        .font(.system(size: UIScale.pt(13), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(agent.machineName) · \(agent.pane)")
                        .font(DashSkin.mono(10))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
            }
            .padding(UIScale.pt(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetBar(
                cornerRadius: 12,
                fill: DashSkin.paper2(dark),
                stroke: open ? DashSkin.accent(dark).opacity(0.45) : DashSkin.line(dark))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                Text("Agents")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("\(listedAgents.count)")
                    .font(DashSkin.mono(10, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(14))
            .padding(.vertical, UIScale.pt(10))
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing: UIScale.pt(2)) {
                    ForEach(listedAgents) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.horizontal, UIScale.pt(6))
                .padding(.vertical, UIScale.pt(6))
            }
        }
        .frame(width: UIScale.pt(compact ? 200 : 252))
        .frame(maxHeight: .infinity)
        .background(DashSkin.paper(dark))
    }

    private func agentRow(_ agent: HerdrAgent) -> some View {
        let selected = store.selectedTab == agent.id
        return Button {
            openAgent(agent)
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(8)) {
                Circle()
                    .fill(HerdrStatusColor.color(agent.status, dark: dark))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                    .padding(.top, UIScale.pt(5))
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(.top, UIScale.pt(2))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    if hideAgents {
                        hiddenLine
                        Text("\(agent.kind) · \(agent.machineName)")
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                    } else {
                        Text(agent.title)
                            .font(
                                .system(
                                    size: UIScale.pt(12.5), weight: selected ? .semibold : .medium)
                            )
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(agent.kind) · \(agent.machineName) · \(agent.pane)")
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func openAgent(_ agent: HerdrAgent) {
        store.open(agent)
    }

    private var hiddenLine: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(3), style: .continuous)
            .fill(DashSkin.ink(dark).opacity(0.14))
            .frame(height: UIScale.pt(13))
            .frame(maxWidth: UIScale.pt(160), alignment: .leading)
            .accessibilityLabel("Hidden")
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: UIScale.pt(8)) {
            Text(title)
                .font(DashSkin.serif(22))
                .foregroundStyle(DashSkin.ink(dark))
            Text(detail)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(420))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pageContent(compact)
    }
}

enum HerdrStatusColor {
    static func color(_ status: HerdrAgentStatus, dark: Bool) -> Color {
        switch status {
        case .blocked: DashSkin.danger
        case .working: DashSkin.accent(dark)
        case .unknown: DashSkin.inkFaint(dark)
        case .done: DashSkin.sage
        case .idle: DashSkin.inkSoft(dark)
        }
    }
}

private struct KindPillHelp: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.help("Click to add or remove. Command-click to show only this agent.")
        } else {
            content
        }
    }
}
