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
    @State private var draggingTab: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var tabFrames: [String: CGRect] = [:]
    @State private var hoveredCard: String?

    @MainActor init(store: HerdrStore? = nil) {
        _store = State(initialValue: store ?? .shared)
    }

    private var dark: Bool { scheme == .dark }
    private var hideAgents: Bool { presenterState.active && presenterBlurAgents }
    private var onBoard: Bool { store.selectedTab == HerdrStore.boardID }
    private var listedAgents: [HerdrAgent] { store.listedAgents }
    private var machineTerminals: [HerdrAgent] { store.machineTerminals }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            HStack(spacing: 0) {
                if store.railOpen {
                    agentList
                    Divider().opacity(0.35)
                }
                ZStack(alignment: .topLeading) {
                    board.opacity(onBoard ? 1 : 0)
                        .allowsHitTesting(onBoard)
                    ForEach(store.tabs) { tab in
                        HerdrSessionView(
                            store: store, tab: tab, launchEnabled: launchEnabled,
                            hideAgents: hideAgents,
                            presented: tab.id == store.selectedTab
                        )
                        .opacity(tab.id == store.selectedTab ? 1 : 0)
                        .allowsHitTesting(tab.id == store.selectedTab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .background(tabShortcuts)
        .navigationTitle("Herdr")
        .onAppear {
            HerdrAgentWindowDelegate.shared.onClose = { id in
                store.reattach(id)
            }
        }
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
        .accessibilityLabel(store.detailOpen ? "Hide details" : "Show details")
    }

    private func reorder(id: String, location: CGPoint) {
        guard
            let target = tabFrames.first(where: { entry in
                entry.key != id && entry.key != HerdrStore.boardID
                    && location.x >= entry.value.minX && location.x <= entry.value.maxX
            })
        else { return }
        guard target.key != id else { return }
        store.moveTab(id, toIndexOf: target.key)
        dragTranslation = 0
    }

    private var tabShortcuts: some View {
        ZStack {
            ForEach(1...9, id: \.self) { number in
                Button("") { store.selectTab(number: number) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")), modifiers: .option)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var railToggle: some View {
        Button {
            withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                store.setRailOpen(!store.railOpen)
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
        }
        .buttonStyle(.plain)
        .padding(UIScale.pt(4))
        .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
        .pointerCursor()
        .help(store.railOpen ? "Hide the list" : "Show the list")
        .accessibilityLabel(store.railOpen ? "Hide the list" : "Show the list")
    }

    private func viewModes(for tab: HerdrOpenTab) -> some View {
        HStack(spacing: 0) {
            ForEach([HerdrAgentView.agent, .split, .diff], id: \.self) { mode in
                let selected = tab.view == mode
                Button {
                    store.setView(mode, for: tab.id)
                } label: {
                    Text(mode.shortTitle)
                        .font(
                            .system(
                                size: UIScale.pt(11), weight: selected ? .semibold : .medium)
                        )
                        .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(10))
                        .padding(.vertical, UIScale.pt(6))
                        .background(
                            selected ? DashSkin.accent(dark).opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(mode.title)
            }
        }
        .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
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
            HStack(spacing: UIScale.pt(8)) {
                railToggle
                    .padding(.leading, PageMetrics.gutter(compact))
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
                    .padding(.leading, 0)
                    .padding(.vertical, UIScale.pt(8))
                }
                if let tab = store.tabs.first(where: { $0.id == store.selectedTab }),
                    !tab.agent.isTerminal
                {
                    viewModes(for: tab)
                }
                if !onBoard {
                    detailToggle
                        .padding(.trailing, PageMetrics.gutter(compact))
                }
            }
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
        }
        .coordinateSpace(name: HerdrTabFrames.space)
        .onPreferenceChange(HerdrTabFrames.self) { tabFrames = $0 }
        .background(DashSkin.paper2(dark).opacity(0.4))
    }

    private func tabButton(id: String, title: String, closable: Bool, agent: HerdrAgent? = nil)
        -> some View
    {
        let selected = store.selectedTab == id
        return HStack(spacing: UIScale.pt(6)) {
            if let agent {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            } else {
                AppGlyph(.herdr, size: UIScale.pt(13), weight: .semibold)
            }
            Text(title)
                .font(.system(size: UIScale.pt(12), weight: selected ? .semibold : .medium))
                .lineLimit(1)
            if let agent, agent.isTerminal {
                Text(agent.machineName)
                    .font(DashSkin.mono(9))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
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
            fill: agent.map { HerdrStatusColor.fill($0, dark: dark, selected: selected) }
                ?? (selected
                    ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55)),
            stroke: agent.map { HerdrStatusColor.stroke($0, dark: dark, selected: selected) }
                ?? (selected ? DashSkin.lineStrong(dark) : DashSkin.line(dark)),
            strokeWidth: selected ? 1.4 : 1
        )
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HerdrTabFrames.self,
                    value: [id: proxy.frame(in: .named(HerdrTabFrames.space))])
            }
        )
        .offset(x: draggingTab == id ? dragTranslation : 0)
        .zIndex(draggingTab == id ? 1 : 0)
        .onTapGesture { store.selectedTab = id }
        .pointerCursor()
        .gesture(
            id == HerdrStore.boardID
                ? nil
                : DragGesture(minimumDistance: 6, coordinateSpace: .named(HerdrTabFrames.space))
                    .onChanged { value in
                        draggingTab = id
                        dragTranslation = value.translation.width
                        reorder(id: id, location: value.location)
                    }
                    .onEnded { _ in
                        draggingTab = nil
                        dragTranslation = 0
                    }
        )
        .contextMenu { tabContextMenu(id: id, closable: closable) }
        .help(
            agent.map {
                "\($0.isTerminal ? HerdrMachineTerminal.title : $0.kind) · \($0.machineName)"
            }
                ?? "Board")
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
                    .padding(.top, UIScale.pt(46))
                }
            }
        }
    }

    private func column(_ status: HerdrAgentStatus) -> some View {
        let cards = listedAgents.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                Circle()
                    .fill(HerdrStatusColor.color(status, dark: dark))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                Text(status.title)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                if !store.settling {
                    Text("\(cards.count)")
                        .font(DashSkin.mono(10, weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            ScrollView {
                VStack(spacing: UIScale.pt(8)) {
                    if store.settling {
                        HerdrSkeleton(dark: dark, rows: status == .idle ? 3 : 1)
                    } else {
                        ForEach(cards) { agent in
                            card(agent)
                        }
                        if cards.isEmpty {
                            emptyColumnSlot
                        }
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
        let hovered = hoveredCard == agent.id
        return Button {
            openAgent(agent)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                HStack(spacing: UIScale.pt(6)) {
                    HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                        .foregroundStyle(
                            agent.isTerminal ? DashSkin.gold : DashSkin.inkSoft(dark))
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
                fill: HerdrStatusColor.fill(agent, dark: dark, selected: hovered),
                stroke: open
                    ? DashSkin.accent(dark).opacity(hovered ? 0.7 : 0.45)
                    : HerdrStatusColor.stroke(agent, dark: dark, selected: hovered))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { inside in
            if inside {
                hoveredCard = agent.id
            } else if hoveredCard == agent.id {
                hoveredCard = nil
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: hovered)
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    railHeader(
                        "Terminals", count: machineTerminals.count,
                        collapsed: store.terminalsCollapsed
                    ) {
                        store.terminalsCollapsed.toggle()
                    }
                    if !store.terminalsCollapsed {
                        if store.settling {
                            HerdrSkeleton(dark: dark, rows: 2, card: false)
                        } else {
                            ForEach(machineTerminals) { terminal in
                                agentRow(terminal)
                            }
                        }
                    }
                    if !onBoard {
                        railHeader(
                            "Agents", count: listedAgents.count,
                            collapsed: store.agentsCollapsed
                        ) {
                            store.agentsCollapsed.toggle()
                        }
                        if !store.agentsCollapsed, store.settling {
                            HerdrSkeleton(dark: dark, rows: 4, card: false)
                        }
                        if !store.agentsCollapsed, !store.settling {
                            ForEach(listedAgents) { agent in
                                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                    agentRow(agent)
                                    if store.selectedTab == agent.id {
                                        HerdrAgentViewToggle(
                                            selection: store.view(for: agent.id),
                                            compactStyle: true
                                        ) { option in
                                            store.open(agent, showing: option)
                                        }
                                        .padding(.horizontal, UIScale.pt(8))
                                        .padding(.bottom, UIScale.pt(4))
                                    }
                                }
                            }
                        }
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

    private func railHeader(
        _ title: String, count: Int, collapsed: Bool, toggle: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) { toggle() }
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(9), weight: .bold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title)
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("\(count)")
                    .font(DashSkin.mono(10, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.top, UIScale.pt(10))
            .padding(.bottom, UIScale.pt(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
        .accessibilityLabel("\(title), \(collapsed ? "collapsed" : "expanded")")
    }

    private func agentRow(_ agent: HerdrAgent) -> some View {
        let selected = store.selectedTab == agent.id
        return Button {
            openAgent(agent)
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(8)) {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    .foregroundStyle(
                        agent.isTerminal ? DashSkin.gold : DashSkin.inkSoft(dark)
                    )
                    .padding(.top, UIScale.pt(2))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    if hideAgents {
                        hiddenLine
                        Text(agent.machineName)
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
                        Text(rowDetail(agent))
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .widgetBar(
                cornerRadius: 8,
                fill: HerdrStatusColor.fill(agent, dark: dark, selected: selected),
                stroke: selected
                    ? HerdrStatusColor.stroke(agent, dark: dark, selected: true) : .clear,
                strokeWidth: selected ? 1.4 : 0
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func rowDetail(_ agent: HerdrAgent) -> String {
        agent.isTerminal
            ? agent.machineName : "\(agent.kind) · \(agent.machineName) · \(agent.pane)"
    }

    private func openAgent(_ agent: HerdrAgent) {
        let detaching = NSEvent.modifierFlags.contains(.command)
        if detaching {
            store.close(agent.id)
            HerdrAgentWindow.open(agent: agent, store: store, launchEnabled: launchEnabled)
            return
        }
        if HerdrAgentWindow.raise(agent.id) { return }
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

    static func tone(_ agent: HerdrAgent, dark: Bool) -> Color {
        agent.isTerminal ? DashSkin.gold : color(agent.status, dark: dark)
    }

    static func fill(_ agent: HerdrAgent, dark: Bool, selected: Bool) -> Color {
        let base = tone(agent, dark: dark)
        if agent.status == .idle || agent.status == .unknown, !agent.isTerminal {
            return DashSkin.paper2(dark).opacity(selected ? 1 : 0.55)
        }
        return base.opacity(selected ? (dark ? 0.26 : 0.2) : (dark ? 0.16 : 0.12))
    }

    static func stroke(_ agent: HerdrAgent, dark: Bool, selected: Bool) -> Color {
        let base = tone(agent, dark: dark)
        if agent.status == .idle || agent.status == .unknown, !agent.isTerminal {
            return selected ? DashSkin.lineStrong(dark) : DashSkin.line(dark)
        }
        return base.opacity(selected ? 0.65 : 0.4)
    }
}

private struct HerdrTabFrames: PreferenceKey {
    static let space = "herdr.tabs"

    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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
