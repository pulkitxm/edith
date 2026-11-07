import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import SwiftUI

struct HerdrPanePlacement {
    let tab: HerdrTab
    let frame: CGRect
    let visible: Bool

    static func placement(
        of sessionID: String, in tabs: [HerdrTab], rect: CGRect, gap: CGFloat,
        isSelected: (String) -> Bool
    ) -> HerdrPanePlacement? {
        guard let tab = tabs.first(where: { $0.layout.contains(sessionID) }),
            let frame = tab.layout.paneFrames(in: rect, gap: gap)[sessionID]
        else { return nil }
        let shown = isSelected(tab.id)
        guard let zoomed = tab.zoomed else {
            return HerdrPanePlacement(tab: tab, frame: frame, visible: shown)
        }
        return HerdrPanePlacement(
            tab: tab, frame: sessionID == zoomed ? tab.layout.content(in: rect, gap: gap) : frame,
            visible: shown && sessionID == zoomed)
    }
}

struct HerdrCanvas: View {
    var store: HerdrStore
    let launchEnabled: Bool
    let hideAgents: Bool

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var gap: CGFloat { UIScale.pt(6) }

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(store.sessions) { session in
                    HerdrPaneSlot(
                        store: store, session: session, rect: rect, gap: gap,
                        launchEnabled: launchEnabled, hideAgents: hideAgents)
                }
                HerdrCanvasDividers(store: store, rect: rect, gap: gap)
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        }
        .background(DashSkin.paper(dark))
    }
}

struct HerdrPaneSlot: View {
    var store: HerdrStore
    let session: HerdrOpenTab
    let rect: CGRect
    let gap: CGFloat
    let launchEnabled: Bool
    let hideAgents: Bool

    var body: some View {
        if let placement = HerdrPanePlacement.placement(
            of: session.id, in: store.tabs, rect: rect, gap: gap,
            isSelected: store.isTabSelected)
        {
            HerdrPaneView(
                store: store, session: session, placement: placement,
                launchEnabled: launchEnabled, hideAgents: hideAgents
            )
            .frame(width: placement.frame.width, height: placement.frame.height)
            .offset(x: placement.frame.minX, y: placement.frame.minY)
            .opacity(placement.visible ? 1 : 0)
            .allowsHitTesting(placement.visible)
        }
    }
}

struct HerdrCanvasDividers: View {
    var store: HerdrStore
    let rect: CGRect
    let gap: CGFloat

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let tab = store.currentTab, tab.isSplit, tab.zoomed == nil {
            ForEach(tab.layout.paneDividers(in: rect, gap: gap)) { divider in
                HerdrLayoutDividerHandle(
                    axis: divider.axis, dark: scheme == .dark,
                    onDrag: { delta in
                        store.resize(
                            tab.id, split: divider.splitID, index: divider.index,
                            by: Double(delta / divider.span))
                    },
                    onEqualize: { store.equalize(tab.id) }
                )
                .frame(width: divider.rect.width, height: divider.rect.height)
                .offset(x: divider.rect.minX, y: divider.rect.minY)
                .zIndex(2)
            }
        }
    }
}

struct HerdrPaneView: View {
    var store: HerdrStore
    let session: HerdrOpenTab
    let placement: HerdrPanePlacement
    let launchEnabled: Bool
    let hideAgents: Bool

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var tab: HerdrTab { placement.tab }
    private var focused: Bool { tab.focused == session.id }
    private var split: Bool { tab.isSplit }

    private var shown: HerdrOpenTab {
        var shown = session
        shown.view = store.shownView(for: session.id)
        return shown
    }

    var body: some View {
        VStack(spacing: 0) {
            if split {
                HerdrPaneHeader(
                    store: store, session: session, tab: tab, focused: focused,
                    hideAgents: hideAgents)
            }
            HerdrSessionView(
                store: store, tab: shown, launchEnabled: launchEnabled,
                hideAgents: hideAgents, presented: placement.visible,
                wantsFocus: placement.visible && focused
                    && !store.terminalPanels.holdsFocus(tab.id),
                onFocus: { store.focus(session.id) },
                onSetView: { store.setView($0, for: session.id) },
                showsDetails: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: split ? UIScale.pt(7) : 0))
        .overlay {
            if split {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(
                        focused ? DashSkin.accent(dark).opacity(0.75) : DashSkin.line(dark),
                        lineWidth: focused ? UIScale.pt(1.4) : 1
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor
enum HerdrPaneMenu {
    static func items(
        sessionID: String, store: HerdrStore, actions: HerdrAgentActions, launchEnabled: Bool
    ) -> [EdithMenuItem] {
        guard let session = store.session(sessionID), let tab = store.tab(containing: sessionID)
        else { return [] }
        let zoomed = tab.zoomed == sessionID
        let tabAgents = tab.agentIDs.compactMap { store.session($0)?.agent }
        let others = tab.agentIDs.filter { $0 != sessionID }.compactMap(store.session)
        return EdithMenu.items {
            HerdrAgentMenu.items(
                for: session.agent, store: store, actions: actions, launchEnabled: launchEnabled)
            EdithMenuItem.separator
            if tab.isSplit, !HerdrBroadcastGroup.all.recipients(from: tabAgents).isEmpty {
                EdithMenuItem.menu("Message This Tab") {
                    HerdrBroadcastMenu.items(agents: tabAgents, store: store, scopeTitle: "This Tab")
                }
                EdithMenuItem.separator
            }
            EdithMenuItem.button(zoomed ? "Restore Layout" : "Zoom") {
                withAnimation(store.layoutAnimation) {
                    store.toggleZoom(sessionID)
                }
            }
            EdithMenuItem.menu("Swap With") {
                for other in others {
                    EdithMenuItem.button(other.agent.title) {
                        withAnimation(store.layoutAnimation) {
                            store.swap(sessionID, other.id)
                        }
                    }
                }
            }
            EdithMenuItem.separator
            EdithMenuItem.button("Close Pane") {
                withAnimation(store.layoutAnimation) {
                    store.close(sessionID)
                }
            }
        }
    }
}

struct HerdrPaneHeader: View {
    var store: HerdrStore
    let session: HerdrOpenTab
    let tab: HerdrTab
    let focused: Bool
    let hideAgents: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    private var dark: Bool { scheme == .dark }
    private var agent: HerdrAgent { session.agent }
    private var zoomed: Bool { tab.zoomed == session.id }
    @State private var actions = HerdrAgentActions()

    var body: some View {
        let menuItems = paneMenuItems
        return HStack(spacing: UIScale.pt(6)) {
            Button {
                store.focus(session.id)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    HerdrKindMark(kind: agent.kind, size: UIScale.pt(11))
                        .foregroundStyle(
                            agent.isTerminal ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                    Text(agent.title)
                        .font(
                            .edithText(.subheadline).weight(focused ? .semibold : .medium)
                        )
                        .foregroundStyle(focused ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                        .lineLimit(1)
                        .presenterTextBlur(hideAgents, fontSize: 11)
                    Text(agent.machineName)
                        .font(DashSkin.mono(9))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                    Spacer(minLength: UIScale.pt(4))
                }
                .padding(.leading, UIScale.pt(9))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("Focus \(agent.title). ⌥` moves to the next agent, ⌥⌘ arrows move by direction.")
            viewPicker
            iconButton(
                zoomed ? .collapse : .expand,
                help: zoomed ? "Restore the layout (⇧⌘↩)" : "Zoom this agent (⇧⌘↩)"
            ) {
                withAnimation(store.layoutAnimation) {
                    store.toggleZoom(session.id)
                }
            }
            menu(menuItems)
            iconButton(.close, help: "Close \(agent.title)") {
                withAnimation(store.layoutAnimation) {
                    store.close(session.id)
                }
            }
        }
        .padding(.trailing, UIScale.pt(4))
        .frame(height: UIScale.pt(28))
        .background(focused ? DashSkin.accent(dark).opacity(0.1) : DashSkin.paper2(dark))
        .contentShape(Rectangle())
        .herdrDraggable(.agent(agent), simultaneous: true)
        .edithContextMenu(menuItems)
        .modifier(HerdrAgentActionDialogs(actions: actions, store: store))
    }

    private var paneMenuItems: @MainActor () -> [EdithMenuItem] {
        let store = store
        let sessionID = session.id
        let agent = agent
        let actions = actions
        let launchEnabled = launchEnabled
        return {
            HerdrAgentMenu.refreshAccounts(for: [agent], store: store)
            return HerdrPaneMenu.items(
                sessionID: sessionID, store: store, actions: actions,
                launchEnabled: launchEnabled)
        }
    }

    @ViewBuilder
    private var viewPicker: some View {
        let views = store.views(for: session.id)
        if !views.isEmpty {
            let shown = store.shownView(for: session.id)
            HStack(spacing: 0) {
                ForEach(views, id: \.self) { mode in
                    Button {
                        store.setView(mode, for: session.id)
                        store.focus(session.id)
                    } label: {
                        EdithIconView(mode.icon)
                            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                            .foregroundStyle(
                                shown == mode ? DashSkin.ink(dark) : DashSkin.inkFaint(dark)
                            )
                            .frame(width: UIScale.pt(24), height: UIScale.pt(18))
                            .background(
                                shown == mode ? DashSkin.accent(dark).opacity(0.2) : Color.clear)
                    }
                    .buttonStyle(.edith(.borderless))
                    .accessibilityLabel(mode.shortTitle)
                    .accessibilityAddTraits(shown == mode ? .isSelected : [])
                    .help(mode.title)
                }
            }
            .widgetBar(cornerRadius: 6, fill: DashSkin.paper(dark), stroke: DashSkin.line(dark))
        }
    }

    private func menu(_ items: @escaping @MainActor () -> [EdithMenuItem]) -> some View {
        EdithMenuButton(items: items) {
            EdithIcon.more.image(size: 12)
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .borderlessMenu()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for this agent")
    }

    private func iconButton(_ icon: EdithIcon, help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            EdithIconView(icon)
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HerdrLayoutDividerHandle: View {
    let axis: SplitAxis
    let dark: Bool
    let onDrag: (CGFloat) -> Void
    let onEqualize: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        let active = hovering || dragging
        ZStack {
            Capsule()
                .fill(active ? DashSkin.accent(dark) : Color.clear)
                .frame(
                    width: axis == .horizontal ? UIScale.pt(3) : nil,
                    height: axis == .horizontal ? nil : UIScale.pt(3)
                )
                .padding(axis == .horizontal ? .vertical : .horizontal, UIScale.pt(10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            } else if !dragging {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    let travelled =
                        axis == .horizontal ? value.translation.width : value.translation.height
                    let delta = travelled - lastTranslation
                    lastTranslation = travelled
                    onDrag(delta)
                }
                .onEnded { _ in
                    dragging = false
                    lastTranslation = 0
                    if !hovering { NSCursor.arrow.set() }
                }
        )
        .onTapGesture(count: 2, perform: onEqualize)
        .accessibilityLabel("Resize the panes")
        .help("Drag to resize, double-click to even out")
    }
}
