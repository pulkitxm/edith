import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrTabStrip<Content: View>: View {
    let store: HerdrStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        PageTabStrip(selection: store.selectedTab, content: content)
    }
}

struct HerdrTabButton: View, Equatable {
    let store: HerdrStore
    let id: String
    let title: String
    let closable: Bool
    var agents: [HerdrAgent] = []
    var blurTitle = false
    let hideAgents: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    static func == (lhs: HerdrTabButton, rhs: HerdrTabButton) -> Bool {
        lhs.store === rhs.store && lhs.id == rhs.id && lhs.title == rhs.title
            && lhs.closable == rhs.closable && lhs.agents == rhs.agents
            && lhs.blurTitle == rhs.blurTitle && lhs.hideAgents == rhs.hideAgents
    }

    var body: some View {
        let selected = store.isTabSelected(id)
        let agent = agents.count == 1 ? agents.first : nil
        let tone = HerdrStatusColor.mostUrgent(agents)
        return HStack(spacing: UIScale.pt(6)) {
            if agents.count > 1 {
                HerdrKindMarks(agents: agents, dark: dark, size: 11)
            } else if let agent {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            } else {
                AppGlyph(
                    icon: .window, logoName: "herdr", size: UIScale.pt(13))
            }
            Text(title)
                .font(.edithText(.callout).weight(.semibold))
                .lineLimit(1)
                .hidden()
                .overlay(alignment: .leading) {
                    Text(title)
                        .font(
                            .edithText(.callout).weight(selected ? .semibold : .medium)
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
                    EdithIconView(store.copiedID == agent.id ? .check : .terminal)
                        .font(.edithText(.caption))
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
                    EdithIconView(.close)
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
        .edithHoverHighlight(cornerRadius: UIScale.pt(8))
        .contentShape(Rectangle())
        .herdrDropFrame(HerdrDropGeometry.chipPrefix + id)
        .onTapGesture { store.selectedTab = id }
        .modifier(HerdrTabDrag(id: id))
        .herdrAgentContextMenu(agents: agents, store: store) {
            tabContextMenu(id: id, closable: closable)
        }
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
                let agents = tab.agentIDs.compactMap { store.session($0)?.agent }
                if !HerdrBroadcastGroup.all.recipients(from: agents).isEmpty {
                    Menu("Send Message") {
                        HerdrBroadcastMenuItems(
                            agents: agents, store: store, scopeTitle: "This Tab")
                    }
                    Divider()
                }
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
}

struct HerdrTabBarActions: View {
    let store: HerdrStore
    let hideAgents: Bool
    @State private var layoutPopoverOpen = false
    @State private var compactDetailsPresented = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }
    private var onBoard: Bool { store.selectedTab == HerdrStore.boardID }

    var body: some View {
        HStack(spacing: UIScale.pt(4)) {
            if let tab = store.currentTab,
                let sessionID = tab.isSplit ? tab.zoomed : tab.focused,
                let session = store.session(sessionID), !session.agent.isTerminal
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
        .onChange(of: compact) { compactDetailsPresented = false }
    }

    private func layoutButton(for tab: HerdrTab) -> some View {
        let label = tab.isSplit ? "Layout" : "Side by side"
        return Button {
            layoutPopoverOpen.toggle()
        } label: {
            EdithIconView(tab.isSplit ? .grid : .plus)
                .font(.edithText(.callout).weight(.semibold))
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

    private func viewModes(for tab: HerdrOpenTab) -> some View {
        HStack(spacing: 0) {
            ForEach(store.views(for: tab.id), id: \.self) { mode in
                let selected = store.shownView(for: tab.id) == mode
                Button {
                    store.setView(mode, for: tab.id)
                } label: {
                    EdithIconView(mode.icon)
                        .font(.edithText(.subheadline).weight(selected ? .semibold : .medium))
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

    private var terminalToggle: some View {
        let open = store.terminalPanels.isOpen(store.selectedTab)
        return Button {
            withAnimation(store.layoutAnimation) {
                store.perform(.toggle)
            }
        } label: {
            EdithIconView(.terminal)
                .font(.edithText(.callout).weight(.semibold))
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

    private var detailToggle: some View {
        Button {
            if compact {
                compactDetailsPresented.toggle()
            } else {
                withAnimation(store.layoutAnimation) {
                    store.detailOpen.toggle()
                }
            }
        } label: {
            EdithIconView(.sidebarRight)
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
        .buttonStyle(.edith(.borderless))
        .popover(isPresented: $compactDetailsPresented) {
            if let focused = store.focusedSession {
                HerdrAgentDetails(store: store, tab: store.shown(focused), hideAgents: hideAgents)
                    .frame(width: UIScale.pt(260), height: UIScale.pt(360))
            }
        }
        .help(HerdrAgentDetailCommand.help(open: store.detailOpen))
        .accessibilityLabel(!compact && store.detailOpen ? "Hide details" : "Show details")
    }
}
