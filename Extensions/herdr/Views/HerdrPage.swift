import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrPage: View {
    private let activity: AgentActivityMonitor?
    @State private var connectionsPresented = false
    @State private var store: HerdrStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var presenterState = PresenterState.shared
    @State private var drag: HerdrDragCoordinator
    @State private var hoveredCard: String?
    @State private var railDragBaseWidth: Double?
    @State private var liveRailWidth: Double?
    @State private var launchSettingsPresented = false
    @State private var newAgentPopupPresented = false
    @State private var newAgentSpace: HerdrAgentSpace?
    @State private var filterMenu = false
    @State private var compactRailPresented = false
    @State private var filterDismissedAt: Date?
    @State private var keyMonitor = HerdrPageKeyMonitor()

    @MainActor init(
        store: HerdrStore? = nil, drag: HerdrDragCoordinator? = nil,
        activity: AgentActivityMonitor? = nil
    ) {
        self.activity = activity
        _store = State(initialValue: store ?? .shared)
        _drag = State(initialValue: drag ?? HerdrDragCoordinator())
    }

    private var dark: Bool { scheme == .dark }
    private var hideAgents: Bool { presenterState.hidesAgents }
    private var onBoard: Bool { store.selectedTab == HerdrStore.boardID }
    private var tabBinding: Binding<String> {
        Binding(
            get: { onBoard ? "" : store.selectedTab },
            set: { store.selectedTab = $0.isEmpty ? HerdrStore.boardID : $0 })
    }
    private var viewBinding: Binding<String> {
        Binding(
            get: {
                guard !onBoard, let agent = store.focusedSession?.agent.id else { return "" }
                return store.view(for: agent).rawValue
            },
            set: { raw in
                guard !onBoard, let agent = store.focusedSession?.agent.id,
                    let view = HerdrAgentView(rawValue: raw)
                else { return }
                store.setView(view, for: agent)
            })
    }
    private var listedAgents: [HerdrAgent] { store.listedAgents }
    private var machineTerminals: [HerdrAgent] { store.machineTerminals }

    private func herdrTabIsValid(_ id: String) -> Bool {
        id.isEmpty || id == HerdrStore.boardID || store.tab(id) != nil
    }

    private func herdrViewIsValid(_ raw: String) -> Bool {
        raw.isEmpty || HerdrAgentView(rawValue: raw) != nil
    }

    var body: some View {
        PageWorkspace {
            header
            tabBar
        } content: {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if showsRail {
                        agentList
                            .frame(width: min(railDisplayWidth, proxy.size.width * 0.28))
                        HerdrResizeHandle(
                            label: "Resize the agent list",
                            onChanged: resizeRail,
                            onEnded: finishRailResize,
                            onReset: resetRailWidth)
                    }
                    ZStack(alignment: .topLeading) {
                        board.modifier(HerdrBoardVisibility(store: store, showsOnBoard: true))
                        HerdrCanvas(
                            store: store, launchEnabled: launchEnabled, hideAgents: hideAgents
                        )
                        .modifier(HerdrBoardVisibility(store: store, showsOnBoard: false))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .herdrDropFrame(HerdrDropGeometry.canvasKey)
                    HerdrDetailSlot(
                        store: store, hideAgents: hideAgents,
                        maximumWidth: proxy.size.width * 0.3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    HerdrTerminalPanelSlot(
                        store: store, launchEnabled: launchEnabled, hideAgents: hideAgents,
                        size: proxy.size, leading: railLeading(in: proxy.size))
                }
            }
        }
        .overlay { HerdrDragOverlay(drag: drag, store: store, hideAgents: hideAgents) }
        .herdrDropFrame(HerdrDropGeometry.pageKey)
        .coordinateSpace(name: HerdrDragCoordinator.space)
        .environment(drag)
        .navigationRoute(
            "view", selection: viewBinding, isValid: herdrViewIsValid,
            isReady: store.inventoryReady
        )
        .navigationRoute(
            "tab", selection: tabBinding, isValid: herdrTabIsValid,
            isReady: store.inventoryReady
        )
        .onDisappear {
            drag.cancel()
            keyMonitor.active = false
            keyMonitor.remove()
        }
        .onChange(of: automaticActions) { keyMonitor.active = automaticActions }
        .onChange(of: compact) { compactRailPresented = false }
        .modifier(HerdrTabChangeAction(store: store) { compactRailPresented = false })
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .background(tabShortcuts)
        .background(
            HerdrWindowReader(
                onWindow: { store.movePage(from: $0, to: $1) },
                onKey: { [weak store] event in
                    guard automaticActions, let store else { return false }
                    return store.performPageKey(
                        characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                        modifiers: event.modifierFlags, repeats: event.isARepeat,
                        in: event.window)
                })
        )
        .navigationTitle("Agents")
        .onAppear {
            keyMonitor.active = automaticActions
            keyMonitor.install(store: store) { store, event, window in
                store.performPageKey(
                    characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                    modifiers: event.modifierFlags, repeats: event.isARepeat, in: window)
            }
            if store.uiClient == nil {
                HerdrAgentWindowDelegate.shared.onClose = { id in store.reattach(id) }
            }
            drag.store = store
            drag.unit = UIScale.current
            drag.gap = UIScale.pt(6)
            drag.onTearOff = { agent in
                if store.uiClient == nil {
                    if HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
                    store.close(agent.id, rememberingPlacement: false)
                }
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
        .agentTopic(
            .sessions, as: SessionsSnapshot.self, active: automaticActions && store.uiClient == nil
        ) { snapshot in
            store.adopt(snapshot)

        }
        .agentTopic(
            .hooks, as: HerdrHooksSnapshot.self, active: automaticActions && store.uiClient == nil
        ) { snapshot in
            store.messaging.adopt(snapshot)
        }
        .edithSheet(item: messageDraft, dismissible: false) { draft in
            HerdrMessageSheet(messaging: store.messaging, draft: draft, hideAgents: hideAgents)
        }
        .edithSheet(
            isPresented: Binding(
                get: { connectionsPresented || activity?.connectionsPresented == true },
                set: {
                    connectionsPresented = $0; activity?.connectionsPresented = $0
                })
        ) {
            if let activity {
                AgentConnectionsPane(monitor: activity).frame(
                    width: UIScale.pt(680), height: UIScale.pt(650))
            }
        }
        .edithSheet(isPresented: $launchSettingsPresented) {
            HerdrLaunchSettingsSheet(store: store, accounts: store.claudeAccounts)
        }
        .edithSheet(isPresented: $newAgentPopupPresented, dismissible: nil) {
            HerdrNewAgentPopup(store: store)
        }
        .edithSheet(item: $newAgentSpace, dismissible: nil) { space in
            HerdrNewAgentPopup(store: store, space: space)
        }
        .edithSheet(isPresented: $store.searchPresented) {
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

    private var terminalCloseRequested: Binding<Bool> {
        Binding(
            get: { store.terminalPanels.closeRequest != nil },
            set: { if !$0 { store.terminalPanels.closeRequest = nil } })
    }

    private var railDisplayWidth: Double {
        UIScale.pt(HerdrPaneSizing.rail(liveRailWidth ?? store.railWidth))
    }

    private var inventoryLoading: Bool {
        store.hosts.isEmpty && (!store.inventoryReceived || store.refreshing || store.settling)
    }

    private var boardLoading: Bool { inventoryLoading || store.settling }

    private var herdrAvailable: Bool {
        store.hosts.contains(where: \.herdrPresent) || !store.agents.isEmpty
    }

    private var showsRail: Bool {
        store.railOpen && !compact && (inventoryLoading || herdrAvailable)
    }

    private var visibleColumns: [HerdrAgentStatus] {
        store.columns.filter { status in
            status != .unknown || (!boardLoading && listedAgents.contains { $0.status == status })
        }
    }

    private func railLeading(in size: CGSize) -> Double {
        guard showsRail else { return 0 }
        return min(railDisplayWidth, size.width * 0.28) + UIScale.pt(9)
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
        PageHeader(title: { Text("Agents") }, trailing: { headerActions })
    }

    private var headerActions: some View {
        HStack(spacing: UIScale.pt(2)) {
            if activity != nil {
                headerIcon(
                    .link, "Agent connections",
                    "Configure provider activity and permission requests"
                ) { connectionsPresented = true }
            }
            HerdrMessageMenu(store: store)
            headerIcon(
                .search, "Search", "Search agent sessions on every machine (⌘K)"
            ) {
                store.searchPresented = true
            }
            headerIcon(.plus, "New Agent", "New agent (⌘N)") {
                newAgentPopupPresented = true
            }
            headerIcon(.refresh, "Refresh", "Refresh sessions") {
                HerdrWorkOwnership.start { await store.refresh() }
            }
            .disabled(store.refreshing)
        }
    }

    private func headerIcon(
        _ icon: EdithIcon, _ label: String, _ help: String, action: @escaping () -> Void
    ) -> some View {
        PageToolbarButton(
            action: action, icon: icon, helperText: help, accessibilityLabel: label,
            tint: DashSkin.inkSoft(dark), font: .edithText(.headline))
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
            if compact {
                compactRailPresented.toggle()
            } else {
                withAnimation(store.layoutAnimation) {
                    store.setRailOpen(!store.railOpen)
                }
            }
        } label: {
            EdithIconView(.sidebarLeft)
                .font(.edithText(.callout).weight(.semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                .padding(UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark)
                )
        }
        .buttonStyle(
            .edithShaped(
                RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous), filled: true)
        )
        .popover(isPresented: $compactRailPresented) {
            agentList.frame(width: UIScale.pt(260), height: UIScale.pt(420))
        }
        .help(store.railOpen ? "Hide the list" : "Show the list")
        .accessibilityLabel(!compact && store.railOpen ? "Hide the list" : "Show the list")
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: UIScale.pt(1))
            HStack(spacing: UIScale.pt(8)) {
                railToggle
                    .padding(.leading, PageMetrics.gutter(compact))
                sessionFilterButton
                HerdrTabStrip(store: store) {
                    HStack(spacing: UIScale.pt(6)) {
                        HerdrTabButton(
                            store: store, id: HerdrStore.boardID, title: "Board", closable: false,
                            hideAgents: hideAgents
                        )
                        .equatable()
                        .id(HerdrStore.boardID)
                        ForEach(store.tabs) { tab in
                            let agents = tab.agentIDs.compactMap { store.session($0)?.agent }
                            HerdrTabButton(
                                store: store, id: tab.id,
                                title: agents.first?.title ?? "Agent",
                                closable: true, agents: agents, blurTitle: hideAgents,
                                hideAgents: hideAgents
                            )
                            .equatable()
                            .id(tab.id)
                        }
                    }
                    .padding(.leading, 0)
                    .padding(.vertical, UIScale.pt(8))
                }
                HerdrTabBarActions(store: store, hideAgents: hideAgents)
            }
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: UIScale.pt(1))
        }
        .herdrDropFrame(HerdrDropGeometry.tabBarKey)
        .background(DashSkin.paper2(dark).opacity(0.4))
    }

    private var board: some View {
        Group {
            if boardLoading {
                boardColumns
            } else if store.agents.isEmpty, let failure = store.inventoryFailureMessage {
                PageEmptyState(
                    icon: .warning,
                    title: "Edith could not read your agents",
                    message: failure,
                    primary: refreshAction(title: "Try Again"),
                    footnote:
                        "Your running agents are unaffected. If this keeps happening, run herdr in Terminal to see the full error.",
                    tint: DashSkin.danger
                )
                .pageContent(compact)
            } else if store.hosts.isEmpty {
                PageEmptyState(
                    icon: .display,
                    title: "No machines found yet",
                    message:
                        "Edith looks for Herdr on this Mac and on every machine you add in Machines. Check again once one is set up.",
                    primary: refreshAction(title: "Check Again")
                )
                .pageContent(compact)
            } else if !herdrAvailable {
                PageEmptyState(
                    icon: .box,
                    title: "Install Herdr to start agents",
                    message:
                        "Herdr keeps coding agents like Claude Code and Codex running in terminal panes you can leave and come back to. Edith shows them here once the herdr command is installed.",
                    steps: [
                        PageGuideStep(
                            icon: .arrowDown, title: "Install herdr",
                            detail:
                                "On this Mac or on a machine you reach over SSH. Edith checks your PATH, ~/.local/bin and Homebrew."
                        ),
                        PageGuideStep(
                            icon: .refresh, title: "Check again",
                            detail:
                                "Edith finds the herdr command and lists every machine that has it."
                        ),
                        PageGuideStep(
                            icon: .plus, title: "Start an agent",
                            detail:
                                "Pick a coding agent and a project, and it opens in its own pane."
                        ),
                    ],
                    primary: refreshAction(title: "Check Again"),
                    footnote: "Edith never installs anything for you."
                )
                .pageContent(compact)
            } else if store.agents.isEmpty {
                PageEmptyState(
                    icon: .columns,
                    title: "No agents running",
                    message:
                        "Start a coding agent and it shows up here, sorted by whether it needs you, is working or is done.",
                    steps: [
                        PageGuideStep(
                            icon: .herdr, title: "Choose an agent",
                            detail: "Claude Code, Codex or any other agent Herdr knows."),
                        PageGuideStep(
                            icon: .display, title: "Pick a machine",
                            detail: "This Mac or any SSH machine that has herdr installed."),
                        PageGuideStep(
                            icon: .grid, title: "Name a space",
                            detail:
                                "A space groups the panes for one project. Reuse one or type a new name."
                        ),
                    ],
                    primary: PageAction(
                        "New Agent", icon: .plus, identifier: "herdr.empty.new-agent"
                    ) { newAgentPopupPresented = true },
                    footnote:
                        "Agents keep running when you leave this page. Blocked agents move to the front so you can answer them."
                )
                .pageContent(compact)
            } else {
                boardColumns
            }
        }
    }

    private var boardColumns: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - 2 * PageMetrics.gutter(compact)
            if compact || !lanesFit(available: available, count: visibleColumns.count) {
                boardSections
            } else {
                boardLanes(available: available)
            }
        }
    }

    private func lanesFit(available: CGFloat, count: Int) -> Bool {
        let gaps = UIScale.pt(PageMetrics.cardSpacing) * CGFloat(max(0, count - 1))
        return (available - gaps) / CGFloat(max(1, count)) >= UIScale.pt(184)
    }

    private var boardSections: some View {
        let populated = visibleColumns.filter { status in
            listedAgents.contains { $0.status == status }
        }
        let statuses = boardLoading || populated.isEmpty ? visibleColumns : populated
        return ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(24)) {
                ForEach(statuses, id: \.self) { status in
                    let cards = listedAgents.filter { $0.status == status }
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        columnHeader(status, count: cards.count)
                        LazyVStack(spacing: UIScale.pt(8)) {
                            if boardLoading {
                                HerdrSkeleton(dark: dark, rows: 1)
                            } else if cards.isEmpty {
                                emptyColumnSlot(status)
                            } else {
                                ForEach(cards) { agent in card(agent) }
                            }
                        }
                    }
                }
            }
            .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
            .pageContent(compact)
        }
    }

    private func columnHeader(_ status: HerdrAgentStatus, count: Int) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Circle()
                .fill(HerdrStatusColor.color(status, dark: dark))
                .frame(width: UIScale.pt(8), height: UIScale.pt(8))
            Text(status.title)
                .font(.edithText(.callout)).fontWeight(.semibold)
                .foregroundStyle(DashSkin.ink(dark))
            if !boardLoading {
                Text("\(count)")
                    .font(.edithText(.caption)).monospacedDigit()
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(.horizontal, UIScale.pt(4))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func boardLanes(available: CGFloat) -> some View {
        let statuses = visibleColumns
        let gaps = UIScale.pt(PageMetrics.cardSpacing) * CGFloat(max(0, statuses.count - 1))
        let width = (available - gaps) / CGFloat(max(1, statuses.count))
        return HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            ForEach(statuses, id: \.self) { status in
                column(status, width: width)
            }
        }
        .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
        .pageContent(compact)
    }

    private func column(_ status: HerdrAgentStatus, width: CGFloat) -> some View {
        let cards = listedAgents.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            columnHeader(status, count: cards.count)
            ScrollView {
                VStack(spacing: UIScale.pt(8)) {
                    if boardLoading {
                        HerdrSkeleton(dark: dark, rows: status == .working ? 2 : 1)
                    } else {
                        ForEach(cards) { agent in
                            card(agent)
                        }
                        if cards.isEmpty {
                            emptyColumnSlot(status)
                        }
                    }
                }
                .padding(.bottom, UIScale.pt(4))
            }
            .scrollIndicators(.never)
        }
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: UIScale.pt(220), alignment: .topLeading)
    }

    private func emptyColumnSlot(_ status: HerdrAgentStatus) -> some View {
        let message =
            switch status {
            case .blocked: "Nothing needs you"
            case .working: "Nothing running"
            case .done: "Nothing finished yet"
            case .idle: "No idle agents"
            case .unknown: "Nothing here"
            }
        return RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
            .strokeBorder(
                DashSkin.line(dark),
                style: StrokeStyle(lineWidth: 1, dash: [UIScale.pt(4), UIScale.pt(4)])
            )
            .frame(height: UIScale.pt(72))
            .overlay {
                Text(message)
                    .font(.edithText(.callout))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, UIScale.pt(12))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(status.title): \(message)")
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
                            agent.isTerminal ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                    Text(agent.kind)
                        .font(.edithText(.caption).weight(.semibold))
                    Spacer(minLength: 0)
                    if open {
                        Text("Open")
                            .font(.edithText(.caption).weight(.semibold))
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
                    .font(.edithText(.body).weight(.medium))
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
        .buttonStyle(
            .edithShaped(
                RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous), filled: true)
        )
        .onHover { inside in
            if inside {
                hoveredCard = agent.id
            } else if hoveredCard == agent.id {
                hoveredCard = nil
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: hovered)
        .herdrDraggable(.agent(agent), simultaneous: true)
        .herdrAgentContextMenu(agent, store: store)
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
                        if boardLoading {
                            HerdrSkeleton(dark: dark, rows: 2, card: false)
                        } else {
                            railRows(machineTerminals)
                        }
                    }
                    agentsRailHeader
                    if !store.agentsCollapsed, boardLoading {
                        HerdrSkeleton(dark: dark, rows: 4, card: false)
                    }
                    if !store.agentsCollapsed, !boardLoading {
                        if store.spaceGroupingEnabled {
                            ForEach(store.agentSpaces) { space in
                                let visible = space.agents
                                if !visible.isEmpty {
                                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                        spaceHeader(space, count: visible.count)
                                        if !store.spaceIsCollapsed(space.id) {
                                            ForEach(visible) { agent in
                                                agentRow(agent)
                                            }
                                        }
                                    }
                                    .herdrDropFrame(HerdrDropGeometry.spacePrefix + space.id)
                                }
                            }
                        } else {
                            railRows(listedAgents)
                        }
                    }
                }
                .padding(.horizontal, UIScale.pt(8))
                .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop - 10))
                .padding(.bottom, UIScale.pt(8))
            }
        }
        .frame(maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .herdrDropFrame(HerdrDropGeometry.sidebarKey)
    }

    private var agentsRailHeader: some View {
        HStack(spacing: UIScale.pt(4)) {
            railHeader(
                "Agents", count: listedAgents.count,
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
                        .font(.edithText(.caption).weight(.medium))
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

    private func railRows(_ agents: [HerdrAgent]) -> some View {
        ForEach(agents) { agent in
            agentRow(agent)
        }
    }

    private func spaceMessageMenu(_ space: HerdrAgentSpace, accessibleTitle: String) -> some View {
        Menu {
            HerdrBroadcastMenuItems(
                agents: space.agents, store: store, scopeTitle: space.title, redactScope: true)
        } label: {
            EdithIcon.send.image(size: 12)
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .borderlessMenu()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Message agents in \(accessibleTitle)")
        .accessibilityLabel("Message agents in \(accessibleTitle)")
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
                    EdithIconView(.chevronRight)
                        .font(.system(size: UIScale.pt(8), weight: .bold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(space.title)
                        .font(.edithText(.caption).weight(.semibold))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                        .presenterTextBlur(hideAgents, fontSize: 10.5)
                    if store.agentSpaces.contains(where: {
                        $0.title == space.title && $0.id != space.id
                    }),
                        let machineName = space.agents.first?.machineName
                    {
                        Text(machineName)
                            .font(DashSkin.mono(9))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                            .presenterTextBlur(hideAgents, fontSize: 9)
                    }
                    Text("\(shownCount)")
                        .font(DashSkin.mono(9.5, weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: UIScale.pt(22))
                .padding(.leading, UIScale.pt(14))
                .padding(.top, UIScale.pt(7))
                .padding(.bottom, UIScale.pt(3))
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("\(collapsed ? "Show" : "Hide") \(accessibleTitle). Drag to reorder spaces.")
            .accessibilityLabel("\(accessibleTitle), \(collapsed ? "collapsed" : "expanded")")
            .herdrDraggable(.space(space.id), simultaneous: true)

            HStack(spacing: UIScale.pt(2)) {
                spaceHeaderActions(space, accessibleTitle: accessibleTitle)
            }
            .padding(.top, UIScale.pt(7))
            .padding(.bottom, UIScale.pt(3))
        }
        .contextMenu {
            if !HerdrBroadcastGroup.all.recipients(from: space.agents).isEmpty {
                Menu("Send Message") {
                    HerdrBroadcastMenuItems(
                        agents: space.agents, store: store, scopeTitle: space.title,
                        redactScope: true)
                }
            }
        }
        .padding(.trailing, UIScale.pt(6))
    }

    @ViewBuilder
    private func spaceHeaderActions(_ space: HerdrAgentSpace, accessibleTitle: String)
        -> some View
    {
        if !HerdrBroadcastGroup.all.recipients(from: space.agents).isEmpty {
            spaceMessageMenu(space, accessibleTitle: accessibleTitle)
        }

        Button {
            newAgentSpace = space
        } label: {
            EdithIconView(.plus)
                .font(.edithText(.caption).weight(.semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
        }
        .buttonStyle(.edith(.borderless))
        .disabled(
            space.agents.first?.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false
        )
        .help("New agent in \(accessibleTitle)")
        .accessibilityLabel("New agent in \(accessibleTitle)")

        Button {
            openSpace(space)
        } label: {
            EdithIconView(.window)
                .font(.edithText(.caption).weight(.semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
        }
        .buttonStyle(.edith(.borderless))
        .help("Open \(accessibleTitle) in a new window")
        .accessibilityLabel("Open \(accessibleTitle) in a new window")
    }

    private func railHeader(
        _ title: String, count: Int, collapsed: Bool, toggle: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) { toggle() }
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                EdithIconView(.chevronRight)
                    .font(.system(size: UIScale.pt(9), weight: .bold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title)
                    .font(.edithText(.callout)).fontWeight(.semibold)
                    .foregroundStyle(DashSkin.ink(dark))
                if !boardLoading {
                    Text("\(count)")
                        .font(.edithText(.caption)).monospacedDigit()
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
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

    private func agentRow(_ agent: HerdrAgent) -> some View {
        HerdrRailRow(
            store: store, agent: agent, hideAgents: hideAgents, launchEnabled: launchEnabled
        )
        .equatable()
    }

    private func openAgent(_ agent: HerdrAgent) {
        HerdrRailRow.open(agent, store: store, launchEnabled: launchEnabled)
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

    private func refreshAction(title: String) -> PageAction {
        PageAction(title, icon: .refresh, identifier: "herdr.empty.refresh") {
            guard !store.refreshing else { return }
            HerdrWorkOwnership.start { await store.refresh() }
        }
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
        agent.isTerminal ? DashSkin.accent(dark) : color(agent.status, dark: dark)
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

struct HerdrTabDrag: ViewModifier {
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
    func accessibilityValueIfPresent(_ value: String) -> some View {
        if value.isEmpty {
            self
        } else {
            accessibilityValue(value)
        }
    }
}

struct HerdrWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?, NSWindow?) -> Void
    var onKey: ((NSEvent) -> Bool)?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
        view.onKey = onKey
    }

    final class ReaderView: NSView {
        private static let readers = NSHashTable<ReaderView>.weakObjects()
        var onWindow: ((NSWindow?, NSWindow?) -> Void)?
        var onKey: ((NSEvent) -> Bool)?
        private weak var current: NSWindow?

        static func performKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
            guard event.type == .keyDown, let window else { return false }
            return readers.allObjects.contains { reader in
                reader.window === window && reader.onKey?(event) == true
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown, onKey?(event) == true { return true }
            return super.performKeyEquivalent(with: event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Self.readers.remove(self) } else { Self.readers.add(self) }
            guard current !== window else { return }
            onWindow?(current, window)
            current = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
