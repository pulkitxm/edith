import EdithKit
import SwiftUI

struct HerdrPage: View {
    @State private var store = HerdrStore()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @AppStorage(AppStorageKeys.General.mainSidebarOpen, store: SharedDefaults.store) private
        var sidebarOpen = true

    private var dark: Bool { scheme == .dark }
    private var onBoard: Bool { store.selectedTab == HerdrStore.boardID }
    private var listedAgents: [HerdrAgent] {
        store.filteredAgents.isEmpty ? store.agents : store.filteredAgents
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.35)
            HStack(spacing: 0) {
                if !onBoard {
                    agentList
                    Divider().opacity(0.35)
                }
                ZStack {
                    board.opacity(onBoard ? 1 : 0)
                        .allowsHitTesting(onBoard)
                    ForEach(store.tabs) { tab in
                        HerdrSessionView(store: store, tab: tab, launchEnabled: launchEnabled)
                            .opacity(tab.id == store.selectedTab ? 1 : 0)
                            .allowsHitTesting(tab.id == store.selectedTab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Herdr")
        .task(id: automaticActions) {
            guard automaticActions else { return }
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await store.refresh()
            }
        }
        .onChange(of: store.selectedTab) { _, tab in
            sidebarOpen = tab == HerdrStore.boardID
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

    private var filters: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            pillRow(
                items: store.machineChoices.map { ($0.id, $0.name) },
                selected: store.machineFilter
            ) { store.machineFilter = $0 }
            pillRow(
                items: [("all", "Any agent")] + store.kindChoices.map { ($0, $0) },
                selected: store.kindFilter,
                showsKindMark: true
            ) { store.kindFilter = $0 }
        }
    }

    private func pillRow(
        items: [(String, String)], selected: String, showsKindMark: Bool = false,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(6)) {
                ForEach(items, id: \.0) { item in
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
                            item.0 == selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
                        )
                        .padding(.horizontal, UIScale.pt(10))
                        .padding(.vertical, UIScale.pt(5))
                        .widgetBar(
                            cornerRadius: 8,
                            fill: item.0 == selected
                                ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55),
                            stroke: item.0 == selected
                                ? DashSkin.accent(dark).opacity(0.55) : DashSkin.line(dark),
                            strokeWidth: item.0 == selected ? 1.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(4)) {
                tabButton(id: HerdrStore.boardID, title: "Board", closable: false)
                ForEach(store.tabs) { tab in
                    tabButton(id: tab.id, title: tab.agent.title, closable: true, agent: tab.agent)
                }
            }
            .padding(.horizontal, PageMetrics.gutter(compact))
            .padding(.bottom, UIScale.pt(8))
        }
    }

    private func tabButton(id: String, title: String, closable: Bool, agent: HerdrAgent? = nil)
        -> some View
    {
        let selected = store.selectedTab == id
        return HStack(spacing: UIScale.pt(6)) {
            if let agent {
                Circle()
                    .fill(HerdrStatusColor.color(agent.status, dark: dark))
                    .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(11))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            Button {
                store.selectedTab = id
            } label: {
                Text(title)
                    .font(.system(size: UIScale.pt(12), weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
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
            }
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(6))
        .widgetBar(
            cornerRadius: 8,
            fill: selected ? DashSkin.paper2(dark) : Color.clear,
            stroke: selected ? DashSkin.lineStrong(dark) : Color.clear
        )
        .pointerCursor()
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
                    .padding(.top, UIScale.pt(4))
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
                    Text(agent.title)
                        .font(
                            .system(size: UIScale.pt(12.5), weight: selected ? .semibold : .medium)
                        )
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(agent.kind) · \(agent.machineName) · \(agent.pane)")
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
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
        sidebarOpen = false
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
