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
    @State private var drag: HerdrDragCoordinator
    @State private var hoveredCard: String?
    @State private var railDragBaseWidth: Double?
    @State private var liveRailWidth: Double?
    @State private var layoutPopoverOpen = false
    @State private var launchSettingsPresented = false
    @State private var newAgentPopupPresented = false
    @State private var filterMenu = false
    @State private var filterDismissedAt: Date?

    @MainActor init(store: HerdrStore? = nil, drag: HerdrDragCoordinator? = nil) {
        _store = State(initialValue: store ?? .shared)
        _drag = State(initialValue: drag ?? HerdrDragCoordinator())
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
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if store.railOpen {
                        agentList
                            .frame(width: railDisplayWidth)
                        HerdrResizeHandle(
                            label: "Resize the agent list",
                            onChanged: resizeRail,
                            onEnded: finishRailResize,
                            onReset: resetRailWidth)
                    }
                    ZStack(alignment: .topLeading) {
                        board.opacity(onBoard ? 1 : 0)
                            .allowsHitTesting(onBoard)
                        HerdrCanvas(
                            store: store, launchEnabled: launchEnabled, hideAgents: hideAgents,
                            active: !onBoard
                        )
                        .opacity(onBoard ? 0 : 1)
                        .allowsHitTesting(!onBoard)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .herdrDropFrame(HerdrDropGeometry.canvasKey)
                    .overlay(alignment: .bottom) {
                        HerdrTerminalPanelView(
                            store: store, owner: store.selectedTab, launchEnabled: launchEnabled,
                            maximumHeight: proxy.size.height, hideAgents: hideAgents)
                    }
                    if !onBoard, store.detailOpen, let focused = store.focusedSession {
                        HerdrDetailColumn(
                            store: store, tab: shown(focused), hideAgents: hideAgents)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay { HerdrDragOverlay(drag: drag, store: store, hideAgents: hideAgents) }
        .herdrDropFrame(HerdrDropGeometry.pageKey)
        .coordinateSpace(name: HerdrDragCoordinator.space)
        .onPreferenceChange(HerdrDropFrames.self) { drag.frames = $0 }
        .environment(drag)
        .onDisappear { drag.cancel() }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .background(tabShortcuts)
        .background(HerdrWindowReader { store.movePage(from: $0, to: $1) })
        .navigationTitle("Herdr")
        .onAppear {
            HerdrAgentWindowDelegate.shared.onClose = { id in
                store.reattach(id)
            }
            drag.store = store
            drag.unit = UIScale.current
            drag.gap = UIScale.pt(6)
            drag.onTearOff = { agent in
                if HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
                store.close(agent.id)
                HerdrAgentWindow.open(agent: agent, store: store, launchEnabled: launchEnabled)
            }
        }
        .task(id: automaticActions) {
            if automaticActions {
                await store.watch()
            } else {
                store.stopWatching()
            }
        }
        .agentTopic(.sessions, as: SessionsSnapshot.self, active: automaticActions) { snapshot in
            store.adopt(snapshot)

        }
        .agentTopic(.hooks, as: HerdrHooksSnapshot.self, active: automaticActions) { snapshot in
            store.messaging.adopt(snapshot)
        }
        .sheet(item: messageDraft) { draft in
            HerdrMessageSheet(messaging: store.messaging, draft: draft, hideAgents: hideAgents)
        }
        .sheet(isPresented: $launchSettingsPresented) {
            HerdrLaunchSettingsSheet()
        }
        .sheet(isPresented: $newAgentPopupPresented) {
            HerdrNewAgentPopup(store: store)
        }
        .sheet(isPresented: $store.searchPresented) {
            HerdrSearchPopup(store: store) { agent in openAgent(agent) }
        }
        .alert(
            store.terminalPanels.closeRequest?.title ?? "", isPresented: terminalCloseRequested,
            presenting: store.terminalPanels.closeRequest
        ) { request in
            Button(request.confirmation, role: .destructive) {
                store.terminalPanels.closeRequest = nil
                request.proceed()
            }
            Button("Cancel", role: .cancel) {
                store.terminalPanels.closeRequest = nil
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var messageDraft: Binding<HerdrMessageDraft?> {
        Binding(
            get: { store.messaging.draft.flatMap { $0.presenterID == nil ? $0 : nil } },
            set: { store.messaging.draft = $0 })
    }

    private var messageMenu: some View {
        let agents = store.filteredAgents
        return Menu {
            ForEach(HerdrBroadcastGroup.allCases) { group in
                let count = group.recipients(from: agents).count
                Button("\(group.title) (\(count))") {
                    store.messaging.compose(group, from: agents)
                }
                .disabled(count == 0)
            }
        } label: {
            Image(systemName: "paperplane")
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Message")
        .help("Send a message to every working or stopped agent in the list")
    }

    private var terminalCloseRequested: Binding<Bool> {
        Binding(
            get: { store.terminalPanels.closeRequest != nil },
            set: { if !$0 { store.terminalPanels.closeRequest = nil } })
    }

    private func shown(_ session: HerdrOpenTab) -> HerdrOpenTab {
        var shown = session
        shown.view = store.shownView(for: session.id)
        return shown
    }

    private var railDisplayWidth: Double {
        UIScale.pt(HerdrPaneSizing.rail(liveRailWidth ?? store.railWidth))
    }

    private func resizeRail(_ translation: CGFloat) {
        let base = railDragBaseWidth ?? railDisplayWidth
        railDragBaseWidth = base
        liveRailWidth = HerdrPaneSizing.rail(
            (base + translation) / UIScale.current)
    }

    private func finishRailResize() {
        if let liveRailWidth { store.railWidth = liveRailWidth }
        liveRailWidth = nil
        railDragBaseWidth = nil
    }

    private func resetRailWidth() {
        liveRailWidth = nil
        railDragBaseWidth = nil
        store.railWidth = HerdrPaneSizing.railDefault
    }

    private var header: some View {
        PageHeader(title: { Text("Herdr") }, trailing: { headerActions })
    }

    private var headerActions: some View {
        HStack(spacing: UIScale.pt(2)) {
            messageMenu
            headerIcon(
                "magnifyingglass", "Search", "Search agent sessions on every machine (⌘K)"
            ) {
                store.searchPresented = true
            }
            headerIcon("plus", "New Agent", "New agent (⌘N)") {
                newAgentPopupPresented = true
            }
            headerIcon("arrow.clockwise", "Refresh", "Refresh sessions") {
                Task { await store.refresh() }
            }
            .disabled(store.refreshing)
        }
    }

    private func headerIcon(
        _ symbol: String, _ label: String, _ help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.toolbar))
        .accessibilityLabel(label)
        .help(help)
    }

    private var detailToggle: some View {
        Button {
            withAnimation(store.layoutAnimation) {
                store.detailOpen.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                .padding(UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark)
                )
        }
        .buttonStyle(.edith(.borderless))
        .help(store.detailOpen ? "Hide details" : "Show details")
        .accessibilityLabel(store.detailOpen ? "Hide details" : "Show details")
    }

    private var terminalToggle: some View {
        let open = store.terminalPanels.isOpen(store.selectedTab)
        return Button {
            withAnimation(store.layoutAnimation) {
                store.perform(.toggle)
            }
        } label: {
            Image(systemName: "apple.terminal")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(open ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                .padding(UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: open ? DashSkin.accent(dark).opacity(0.18) : DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark)
                )
        }
        .buttonStyle(.edith(.borderless))
        .help(open ? "Hide terminals (⌃` or ⌘J)" : "Show terminals (⌃` or ⌘J)")
        .accessibilityLabel(open ? "Hide terminals" : "Show terminals")
    }

    private var tabShortcuts: some View {
        ZStack {
            ForEach(1...9, id: \.self) { number in
                Button("") { store.selectTab(number: number) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            if let space = store.agentSpaces.first {
                Button("") { openSpace(space) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            Button("") { store.reopenLastClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { newAgentPopupPresented = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { toggleFilterMenu() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var railToggle: some View {
        Button {
            withAnimation(store.layoutAnimation) {
                store.setRailOpen(!store.railOpen)
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                .padding(UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark)
                )
        }
        .buttonStyle(.edith(.borderless))
        .help(store.railOpen ? "Hide the list" : "Show the list")
        .accessibilityLabel(store.railOpen ? "Hide the list" : "Show the list")
    }

    private func viewModes(for tab: HerdrOpenTab) -> some View {
        HStack(spacing: 0) {
            ForEach(store.views(for: tab.id), id: \.self) { mode in
                let selected = store.shownView(for: tab.id) == mode
                Button {
                    store.setView(mode, for: tab.id)
                } label: {
                    Image(systemName: mode.icon)
                        .font(
                            .system(
                                size: UIScale.pt(11), weight: selected ? .semibold : .medium)
                        )
                        .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                        .frame(width: UIScale.pt(26), height: UIScale.pt(22))
                        .background(selected ? DashSkin.accent(dark).opacity(0.18) : Color.clear)
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(mode.title)
            }
        }
        .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session view")
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
            HStack(spacing: UIScale.pt(8)) {
                railToggle
                    .padding(.leading, PageMetrics.gutter(compact))
                sessionFilterButton
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: UIScale.pt(6)) {
                        tabButton(id: HerdrStore.boardID, title: "Board", closable: false)
                        ForEach(store.tabs) { tab in
                            let agents = tab.agentIDs.compactMap { store.session($0)?.agent }
                            tabButton(
                                id: tab.id,
                                title: agents.first?.title ?? "Agent",
                                closable: true, agents: agents, blurTitle: hideAgents)
                        }
                    }
                    .padding(.leading, 0)
                    .padding(.vertical, UIScale.pt(8))
                }
                tabBarActions
            }
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
        }
        .herdrDropFrame(HerdrDropGeometry.tabBarKey)
        .background(DashSkin.paper2(dark).opacity(0.4))
    }

    private var tabBarActions: some View {
        HStack(spacing: UIScale.pt(4)) {
            if let tab = store.currentTab, !tab.isSplit,
                let session = store.session(tab.focused), !session.agent.isTerminal
            {
                viewModes(for: session)
            }
            if let tab = store.currentTab {
                layoutButton(for: tab)
            }
            terminalToggle
            if !onBoard {
                detailToggle
            }
        }
        .padding(.trailing, PageMetrics.gutter(compact))
    }

    private func layoutButton(for tab: HerdrTab) -> some View {
        let label = tab.isSplit ? "Layout" : "Side by side"
        return Button {
            layoutPopoverOpen.toggle()
        } label: {
            Image(systemName: tab.isSplit ? "square.grid.2x2" : "plus.rectangle.on.rectangle")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                .padding(UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: layoutPopoverOpen
                        ? DashSkin.accent(dark).opacity(0.18) : DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(label)
        .help(tab.isSplit ? "Arrange the agents in this tab" : "Show agents side by side")
        .popover(isPresented: $layoutPopoverOpen, arrowEdge: .bottom) {
            if let current = store.currentTab {
                HerdrLayoutPopover(store: store, tab: current, hideAgents: hideAgents)
            }
        }
    }

    private func tabButton(
        id: String, title: String, closable: Bool, agents: [HerdrAgent] = [],
        blurTitle: Bool = false
    ) -> some View {
        let selected = store.selectedTab == id
        let agent = agents.count == 1 ? agents.first : nil
        let tone = HerdrStatusColor.mostUrgent(agents)
        return HStack(spacing: UIScale.pt(6)) {
            if agents.count > 1 {
                HerdrKindMarks(agents: agents, dark: dark, size: 11)
            } else if let agent {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            } else {
                AppGlyph(.herdr, size: UIScale.pt(13), weight: .semibold)
            }
            Text(title)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .lineLimit(1)
                .hidden()
                .overlay(alignment: .leading) {
                    Text(title)
                        .font(
                            .system(size: UIScale.pt(12), weight: selected ? .semibold : .medium)
                        )
                        .lineLimit(1)
                        .presenterTextBlur(blurTitle, fontSize: 12)
                }
            if agents.count > 1 {
                Text("+\(agents.count - 1)")
                    .font(DashSkin.mono(9.5, weight: .semibold))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(.horizontal, UIScale.pt(5))
                    .padding(.vertical, UIScale.pt(1))
                    .background(DashSkin.paper(dark).opacity(0.8), in: Capsule())
            }
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
                .buttonStyle(.edith(.borderless))
                .help(store.copiedID == agent.id ? "Copied" : "Copy attach command")
            }
            if closable, store.terminalPanels.isChecking(id) {
                SkeletonGroup {
                    SkeletonBlock(width: 9, height: 9, corner: 4.5)
                }
                .accessibilityLabel("Closing")
            } else if closable {
                Button {
                    store.closeTab(id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .buttonStyle(.edith(.borderless))
                .help("Close")
            }
        }
        .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(6))
        .widgetBar(
            cornerRadius: 8,
            fill: tone.map { HerdrStatusColor.fill($0, dark: dark, selected: selected) }
                ?? (selected
                    ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55)),
            stroke: tone.map { HerdrStatusColor.stroke($0, dark: dark, selected: selected) }
                ?? (selected ? DashSkin.lineStrong(dark) : DashSkin.line(dark)),
            strokeWidth: selected ? 1.4 : 1
        )
        .contentShape(Rectangle())
        .herdrDropFrame(HerdrDropGeometry.chipPrefix + id)
        .onTapGesture { store.selectedTab = id }
        .modifier(HerdrTabDrag(id: id))
        .contextMenu { tabContextMenu(id: id, closable: closable) }
        .help(
            agents.isEmpty
                ? "Board"
                : agents.map {
                    "\($0.isTerminal ? HerdrMachineTerminal.title : $0.kind) · \($0.machineName)"
                }
                .joined(separator: "\n"))
    }

    @ViewBuilder
    private func tabContextMenu(id: String, closable: Bool) -> some View {
        if let tab = store.tab(id) {
            if tab.isSplit {
                Button("Separate Into Tabs") { animate { store.separate(id) } }
            }
            let others = store.tabs.filter { $0.id != id }
            if !others.isEmpty {
                Menu("Move Into") {
                    ForEach(others) { other in
                        Button(tabTitle(other)) { animate { store.merge(id, into: other.id) } }
                    }
                }
                Button("Gather All Tabs Here") { animate { store.gatherAll(into: id) } }
            }
            Divider()
        }
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
        Divider()
        Button("Close All", role: .destructive) {
            store.closeAll()
        }
        .disabled(!store.canCloseAll)
        if closable {
            Button("Close", role: .destructive) {
                store.closeTab(id)
            }
        }
    }

    private func tabTitle(_ tab: HerdrTab) -> String {
        let titles = tab.agentIDs.compactMap { store.session($0)?.agent }
            .map { hideAgents ? $0.kind : $0.title }
        return titles.joined(separator: " · ")
    }

    private func animate(_ change: () -> Void) {
        withAnimation(store.layoutAnimation, change)
    }

    private var board: some View {
        Group {
            if store.hosts.isEmpty, store.refreshing {
                HerdrBoardSkeleton(dark: dark, compact: compact)
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
                Text(agent.title)
                    .font(.system(size: UIScale.pt(13), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .presenterTextBlur(hideAgents, fontSize: 13)
                Text("\(agent.machineName) · \(agent.pane)")
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .presenterTextBlur(hideAgents, fontSize: 10)
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
        .buttonStyle(.edith(.borderless))
        .onHover { inside in
            if inside {
                hoveredCard = agent.id
            } else if hoveredCard == agent.id {
                hoveredCard = nil
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: hovered)
        .herdrDraggable(.agent(agent), simultaneous: true)
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    if showsSplitGroup {
                        splitGroup(store.openSplitAgents)
                    }
                    railHeader(
                        "Terminals", count: catalogAgents(machineTerminals).count,
                        collapsed: store.terminalsCollapsed
                    ) {
                        store.terminalsCollapsed.toggle()
                    }
                    if !store.terminalsCollapsed {
                        if store.settling {
                            HerdrSkeleton(dark: dark, rows: 2, card: false)
                        } else {
                            ForEach(catalogAgents(machineTerminals)) { terminal in
                                agentRow(terminal)
                            }
                        }
                    }
                    agentsRailHeader
                    if !store.agentsCollapsed, store.settling {
                        HerdrSkeleton(dark: dark, rows: 4, card: false)
                    }
                    if !store.agentsCollapsed, !store.settling {
                        if store.spaceGroupingEnabled {
                            ForEach(store.agentSpaces) { space in
                                let visible = catalogAgents(space.agents)
                                if !visible.isEmpty {
                                    spaceHeader(space, count: visible.count)
                                    if !store.spaceIsCollapsed(space.id) {
                                        ForEach(visible) { agent in
                                            agentRow(agent)
                                        }
                                    }
                                }
                            }
                        } else {
                            ForEach(catalogAgents(listedAgents)) { agent in
                                agentRow(agent)
                            }
                        }
                    }
                }
                .padding(.horizontal, UIScale.pt(6))
                .padding(.vertical, UIScale.pt(6))
            }
        }
        .frame(maxHeight: .infinity)
        .background(DashSkin.paper(dark))
    }

    private var agentsRailHeader: some View {
        HStack(spacing: UIScale.pt(4)) {
            railHeader(
                "Agents", count: catalogAgents(listedAgents).count,
                collapsed: store.agentsCollapsed
            ) {
                store.agentsCollapsed.toggle()
            }
            .frame(maxWidth: .infinity)
            if store.spaceGroupingEnabled, !store.agentsCollapsed, !store.agentSpaces.isEmpty {
                let allCollapsed = store.allAgentSpacesCollapsed
                Button {
                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                        store.setAllAgentSpacesCollapsed(!allCollapsed)
                    }
                } label: {
                    Text(allCollapsed ? "Expand all" : "Collapse all")
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
                .padding(.top, UIScale.pt(10))
                .padding(.bottom, UIScale.pt(4))
                .padding(.trailing, UIScale.pt(8))
                .help(allCollapsed ? "Expand every space" : "Collapse every space")
                .accessibilityLabel(allCollapsed ? "Expand all spaces" : "Collapse all spaces")
            }
        }
    }

    private func catalogAgents(_ agents: [HerdrAgent]) -> [HerdrAgent] {
        guard showsSplitGroup else { return agents }
        let grouped = Set(store.openSplitAgents.map(\.id))
        return agents.filter { !grouped.contains($0.id) }
    }

    private func spaceHeader(_ space: HerdrAgentSpace, count: Int? = nil) -> some View {
        let collapsed = store.spaceIsCollapsed(space.id)
        let shownCount = count ?? space.agents.count
        let accessibleTitle = hideAgents ? "Space" : space.title
        return HStack(spacing: UIScale.pt(2)) {
            Button {
                withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                    store.toggleSpace(space.id)
                }
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIScale.pt(8), weight: .bold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(space.title)
                        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                        .presenterTextBlur(hideAgents, fontSize: 10.5)
                    Text("\(shownCount)")
                        .font(DashSkin.mono(9.5, weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(collapsed ? "Show \(accessibleTitle)" : "Hide \(accessibleTitle)")
            .accessibilityLabel("\(accessibleTitle), \(collapsed ? "collapsed" : "expanded")")

            Button {
                openSpace(space)
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(22), height: UIScale.pt(22))
            }
            .buttonStyle(.edith(.borderless))
            .help("Open \(accessibleTitle) in a new window")
            .accessibilityLabel("Open \(accessibleTitle) in a new window")
        }
        .padding(.leading, UIScale.pt(14))
        .padding(.trailing, UIScale.pt(6))
        .padding(.top, UIScale.pt(7))
        .padding(.bottom, UIScale.pt(3))
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
        .buttonStyle(.edith(.borderless))
        .help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
        .accessibilityLabel("\(title), \(collapsed ? "collapsed" : "expanded")")
    }

    private var showsSplitGroup: Bool { store.openSplitAgents.count > 1 }

    private func splitGroup(_ agents: [HerdrAgent]) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                Text("Side by side")
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                Text("\(agents.count)")
                    .font(DashSkin.mono(9.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.top, UIScale.pt(7))
            .padding(.bottom, UIScale.pt(3))
            .accessibilityHidden(true)
            ForEach(agents) { agent in
                agentRow(agent, inGroup: true)
            }
        }
        .padding(.bottom, UIScale.pt(4))
        .widgetBar(
            cornerRadius: 10,
            fill: DashSkin.paper2(dark).opacity(0.72),
            stroke: DashSkin.accent(dark).opacity(0.55),
            strokeWidth: 1.4
        )
        .padding(.horizontal, UIScale.pt(2))
        .padding(.bottom, UIScale.pt(6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(splitGroupLabel(agents))
    }

    private func splitGroupLabel(_ agents: [HerdrAgent]) -> String {
        let noun = agents.count == 1 ? "agent" : "agents"
        guard !hideAgents,
            let focused = agents.first(where: { store.railHighlight(for: $0.id) == .focused })
        else {
            return "Side by side, \(agents.count) \(noun)"
        }
        return "Side by side, \(agents.count) \(noun). Focused, \(focused.title)"
    }

    private func agentRow(_ agent: HerdrAgent, inGroup: Bool = false) -> some View {
        let highlight = store.railHighlight(for: agent.id)
        let selected =
            inGroup
            ? highlight == .focused
            : (!showsSplitGroup && (highlight == .solo || highlight == .focused))
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
                    Text(agent.title)
                        .font(
                            .system(
                                size: UIScale.pt(12.5), weight: selected ? .semibold : .medium)
                        )
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .presenterTextBlur(hideAgents, fontSize: 12.5)
                    Text(rowDetail(agent))
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                        .presenterTextBlur(hideAgents, fontSize: 9.5)
                }
                Spacer(minLength: 0)
                if let waiting = store.messaging.armedHook(for: agent.id) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.accent(dark))
                        .padding(.top, UIScale.pt(2))
                        .help(waiting.schedule.sendsPhrase(now: Date()))
                        .accessibilityLabel(waiting.schedule.sendsPhrase(now: Date()))
                }
            }
            .padding(.leading, UIScale.pt(inGroup ? 8 : 12))
            .padding(.trailing, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(inGroup ? 6 : 8))
            .widgetBar(
                cornerRadius: 8,
                fill: rowFill(agent, inGroup: inGroup, selected: selected),
                stroke: inGroup
                    ? nil
                    : (selected
                        ? HerdrStatusColor.stroke(agent, dark: dark, selected: true) : .clear),
                strokeWidth: selected && !inGroup ? 1.4 : 0
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(DashSkin.accent(dark))
                        .frame(width: UIScale.pt(3))
                        .padding(.vertical, UIScale.pt(6))
                        .padding(.leading, UIScale.pt(inGroup ? 3 : 5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityValueIfPresent(rowValue(highlight, inGroup: inGroup))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(rowHelp(agent, highlight: highlight, inGroup: inGroup, selected: selected))
        .herdrDraggable(.agent(agent), simultaneous: true)
        .contextMenu { agentRowMenu(agent) }
    }

    private func rowFill(_ agent: HerdrAgent, inGroup: Bool, selected: Bool) -> Color {
        if inGroup {
            return selected ? DashSkin.accent(dark).opacity(dark ? 0.22 : 0.14) : .clear
        }
        return HerdrStatusColor.fill(agent, dark: dark, selected: selected)
    }

    private func rowValue(_ highlight: HerdrRailHighlight, inGroup: Bool) -> String {
        if inGroup, highlight == .focused { return "Focused" }
        if inGroup { return "In this side by side tab" }
        if highlight == .solo { return "Open on the right" }
        return ""
    }

    private func rowHelp(
        _ agent: HerdrAgent, highlight: HerdrRailHighlight, inGroup: Bool, selected: Bool
    ) -> String {
        if inGroup, highlight == .focused {
            return "\(agent.title): focused in this side by side tab"
        }
        if inGroup {
            return "\(agent.title): in this side by side tab"
        }
        if selected {
            return "\(agent.title): open on the right"
        }
        return "\(agent.title). Drag onto the right side to place it beside other agents."
    }

    @ViewBuilder
    private func agentRowMenu(_ agent: HerdrAgent) -> some View {
        Button("Open") { openAgent(agent) }
        if let tab = store.currentTab, !onBoard, !tab.layout.contains(agent.id) {
            Menu("Open Beside") {
                Button("Right") { openBeside(agent, .right) }
                Button("Left") { openBeside(agent, .left) }
                Button("Below") { openBeside(agent, .bottom) }
                Button("Above") { openBeside(agent, .top) }
            }
        }
        Button("Open in New Window") {
            if HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
            store.close(agent.id)
            HerdrAgentWindow.open(agent: agent, store: store, launchEnabled: launchEnabled)
        }
        if !agent.isTerminal {
            Divider()
            Button("Send Message…") { store.messaging.compose(to: agent) }
            if let hook = store.messaging.armedHook(for: agent.id) {
                Button("Cancel Waiting Message") {
                    Task { await store.messaging.remove(hook.id) }
                }
                .help(hook.schedule.sendsPhrase(now: Date()))
            }
        }
    }

    private func openBeside(_ agent: HerdrAgent, _ side: InsertSide) {
        if HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
        HerdrAgentWindow.close(agent.id)
        animate { store.open(agent, beside: side) }
    }

    private func rowDetail(_ agent: HerdrAgent) -> String {
        agent.isTerminal
            ? agent.machineName : "\(agent.kind) · \(agent.machineName) · \(agent.pane)"
    }

    private func openAgent(_ agent: HerdrAgent) {
        if HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
        let detaching = NSEvent.modifierFlags.contains(.command)
        if detaching {
            store.close(agent.id)
            HerdrAgentWindow.open(agent: agent, store: store, launchEnabled: launchEnabled)
            return
        }
        if HerdrAgentWindow.raise(agent.id) { return }
        store.open(agent)
    }

    private func openSpace(_ space: HerdrAgentSpace) {
        HerdrSpaceWindow.open(space: space, store: store, launchEnabled: launchEnabled)
    }

    private var sessionFilterButton: some View {
        HerdrFilterButton(
            store: store,
            presented: $filterMenu,
            hideAgents: hideAgents,
            onPress: showFilterMenu,
            onDismissed: { filterDismissedAt = Date() },
            onOpenSpace: openFilteredSpace,
            onEditLaunch: editLaunchSettings)
    }

    private func showFilterMenu() {
        if let filterDismissedAt, Date().timeIntervalSince(filterDismissedAt) < 0.35 {
            self.filterDismissedAt = nil
            return
        }
        filterMenu = true
    }

    private func toggleFilterMenu() {
        filterMenu.toggle()
    }

    private func openFilteredSpace(_ space: HerdrAgentSpace) {
        filterMenu = false
        openSpace(space)
    }

    private func editLaunchSettings() {
        filterMenu = false
        launchSettingsPresented = true
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: UIScale.pt(8)) {
            Text(title)
                .font(DashSkin.heading(22))
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

    static func mostUrgent(_ agents: [HerdrAgent]) -> HerdrAgent? {
        let order: [HerdrAgentStatus] = [.blocked, .working, .done, .idle, .unknown]
        return agents.min { first, second in
            (order.firstIndex(of: first.status) ?? order.count)
                < (order.firstIndex(of: second.status) ?? order.count)
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

private struct HerdrTabDrag: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if id == HerdrStore.boardID {
            content
        } else {
            content.herdrDraggable(.tab(id))
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func accessibilityValueIfPresent(_ value: String) -> some View {
        if value.isEmpty {
            self
        } else {
            accessibilityValue(value)
        }
    }
}

private struct HerdrWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?, NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?, NSWindow?) -> Void)?
        private weak var current: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard current !== window else { return }
            onWindow?(current, window)
            current = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
