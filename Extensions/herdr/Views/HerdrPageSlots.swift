import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrBoardVisibility: ViewModifier {
    let store: HerdrStore
    let showsOnBoard: Bool

    func body(content: Content) -> some View {
        let visible = (store.selectedTab == HerdrStore.boardID) == showsOnBoard
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}

struct HerdrTabChangeAction: ViewModifier {
    let store: HerdrStore
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: store.selectedTab) { action() }
    }
}

struct HerdrDetailSlot: View {
    let store: HerdrStore
    let hideAgents: Bool
    let maximumWidth: CGFloat
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if store.selectedTab != HerdrStore.boardID, store.detailOpen, !compact,
            let focused = store.focusedSession
        {
            HerdrDetailColumn(
                store: store, tab: store.shown(focused), hideAgents: hideAgents,
                maximumWidth: maximumWidth)
        }
    }
}

struct HerdrTerminalPanelSlot: View {
    let store: HerdrStore
    let launchEnabled: Bool
    let hideAgents: Bool
    let size: CGSize
    let leading: Double
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HerdrTerminalPanelView(
            store: store, owner: store.selectedTab, launchEnabled: launchEnabled,
            bounds: bounds, hideAgents: hideAgents)
    }

    private var bounds: HerdrTerminalPanelBounds {
        let unit = max(UIScale.current, 0.001)
        var trailing = 0.0
        if store.selectedTab != HerdrStore.boardID, store.detailOpen, !compact {
            let detail = min(
                size.width * 0.3, UIScale.pt(HerdrPaneSizing.detail(store.detailWidth)))
            trailing = detail + UIScale.pt(9)
        }
        return HerdrTerminalPanelBounds(
            width: size.width / unit, height: size.height / unit, contentLeading: leading / unit,
            contentWidth: max(0, size.width - leading - trailing) / unit)
    }
}

struct HerdrMessageMenu: View {
    let store: HerdrStore
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let store = store
        return PageToolbarMenuButton(
            icon: .send,
            helperText: "Send a message to agents in the list or in the open side-by-side tab",
            accessibilityLabel: "Message", tint: DashSkin.inkSoft(dark), font: .edithText(.headline)
        ) {
            HerdrMessageMenu.items(store: store)
        }
    }

    @MainActor static func items(store: HerdrStore) -> [EdithMenuItem] {
        let agents = store.filteredAgents
        return EdithMenu.items {
            HerdrBroadcastMenu.items(agents: agents, store: store)
            if let tab = store.currentTab, tab.isSplit {
                let tabAgents = tab.agentIDs.compactMap { store.session($0)?.agent }
                if !HerdrBroadcastGroup.all.recipients(from: tabAgents).isEmpty {
                    EdithMenuItem.separator
                    EdithMenuItem.menu("This Tab") {
                        HerdrBroadcastMenu.items(
                            agents: tabAgents, store: store, scopeTitle: "This Tab")
                    }
                }
            }
        }
    }
}
