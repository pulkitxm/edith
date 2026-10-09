import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HerdrAgentActions {
    var agentToDelete: HerdrAgent?
    var failure: String?
    private(set) var deleting: Set<String> = []
    private(set) var openingTerminal: Set<String> = []

    func open(_ agent: HerdrAgent, store: HerdrStore) {
        if HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
        if HerdrAgentWindow.raise(agent.id) { return }
        store.open(agent)
        store.revealWorkspaceWindow()
    }

    func openInNewTab(_ agent: HerdrAgent, store: HerdrStore) {
        HerdrSpaceWindow.removeAgent(agent.id)
        HerdrAgentWindow.close(agent.id)
        withAnimation(store.layoutAnimation) { store.openInNewTab(agent) }
        store.revealWorkspaceWindow()
    }

    func openInNewWindow(_ agent: HerdrAgent, store: HerdrStore, launchEnabled: Bool) {
        HerdrSpaceWindow.removeAgent(agent.id)
        store.close(agent.id, rememberingPlacement: false)
        HerdrAgentWindow.open(agent: agent, store: store, launchEnabled: launchEnabled)
    }

    func openBeside(_ agent: HerdrAgent, store: HerdrStore, tabID: String, side: InsertSide) {
        HerdrSpaceWindow.removeAgent(agent.id)
        HerdrAgentWindow.close(agent.id)
        withAnimation(store.layoutAnimation) { store.open(agent, in: tabID, beside: side) }
        store.revealWorkspaceWindow()
    }

    func openInHerdrTerminal(_ agent: HerdrAgent, store: HerdrStore) async {
        guard openingTerminal.insert(agent.id).inserted else { return }
        defer { openingTerminal.remove(agent.id) }
        do {
            try await store.openInHerdrTerminal(agent)
        } catch {
            failure = error.localizedDescription
        }
    }

    func delete(_ agent: HerdrAgent, store: HerdrStore) async {
        guard deleting.insert(agent.id).inserted else { return }
        defer { deleting.remove(agent.id) }
        do {
            try await store.closeAgent(agent)
            HerdrSpaceWindow.removeAgent(agent.id)
            HerdrAgentWindow.close(agent.id)
            store.reattach(agent.id)
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct HerdrAgentMenu: View {
    let agent: HerdrAgent
    let store: HerdrStore
    let actions: HerdrAgentActions
    var onOpen: () -> Void = {}

    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @AppStorage(AppStorageKeys.Presenter.blurAgents, store: SharedDefaults.store)
    private var presenterBlurAgents = true
    private var hideAgents: Bool { PresenterState.shared.hidesAgents }

    var body: some View {
        Button("Open") {
            onOpen()
            actions.open(agent, store: store)
        }
        Menu("Open In") {
            Button("New Tab") {
                onOpen()
                actions.openInNewTab(agent, store: store)
            }
            Button("New Window") {
                onOpen()
                actions.openInNewWindow(agent, store: store, launchEnabled: launchEnabled)
            }
            let destinations = store.tabs.filter { !$0.layout.contains(agent.id) }
            if !destinations.isEmpty {
                Divider()
                ForEach(destinations) { tab in
                    Menu("Beside \(tabTitle(tab))") {
                        Button("Right") { openBeside(tab, .right) }
                        Button("Left") { openBeside(tab, .left) }
                        Button("Below") { openBeside(tab, .bottom) }
                        Button("Above") { openBeside(tab, .top) }
                    }
                }
            }
        }
        if !agent.isTerminal {
            Button("Open in Herdr Terminal") {
                HerdrWorkOwnership.start {
                    await actions.openInHerdrTerminal(agent, store: store)
                    if actions.failure == nil { onOpen() }
                }
            }
            .disabled(actions.openingTerminal.contains(agent.id))
        }
        Button(store.copiedID == agent.id ? "Copied Open Command" : "Copy Open Command") {
            store.copyAttachCommand(for: agent)
        }
        if !agent.isTerminal {
            Divider()
            Button("Send Message…") {
                onOpen()
                let detached =
                    HerdrSpaceWindow.raise(containingAgent: agent.id)
                    || HerdrAgentWindow.raise(agent.id)
                store.messaging.compose(to: agent, presenterID: detached ? agent.id : nil)
                if !detached { store.revealWorkspaceWindow() }
            }
            if let hook = store.messaging.armedHook(for: agent.id) {
                Button("Cancel Waiting Message") {
                    HerdrWorkOwnership.start { await store.messaging.remove(hook.id) }
                }
                .help(hook.schedule.sendsPhrase(now: Date()))
            }
            Divider()
            Button("Delete Agent…", role: .destructive) { actions.agentToDelete = agent }
                .disabled(actions.deleting.contains(agent.id))
        }
    }

    private func openBeside(_ tab: HerdrTab, _ side: InsertSide) {
        onOpen()
        actions.openBeside(agent, store: store, tabID: tab.id, side: side)
    }

    private func tabTitle(_ tab: HerdrTab) -> String {
        tab.agentIDs.compactMap { store.session($0)?.agent }
            .map { hideAgents ? $0.kind : $0.title }.joined(separator: " · ")
    }
}

struct HerdrAgentActionDialogs: ViewModifier {
    @Bindable var actions: HerdrAgentActions
    let store: HerdrStore

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete this agent?",
                isPresented: Binding(
                    get: { actions.agentToDelete != nil },
                    set: { if !$0 { actions.agentToDelete = nil } }),
                titleVisibility: .visible, presenting: actions.agentToDelete
            ) { agent in
                Button("Delete Agent", role: .destructive) {
                    HerdrWorkOwnership.start { await actions.delete(agent, store: store) }
                }
                Button("Cancel", role: .cancel) { actions.agentToDelete = nil }
            } message: { agent in
                Text("\(agent.title) will exit and its Herdr pane will close.")
            }
            .alert(
                "Could not complete agent action",
                isPresented: Binding(
                    get: { actions.failure != nil },
                    set: { if !$0 { actions.failure = nil } })
            ) {
                Button("OK") { actions.failure = nil }
            } message: {
                Text(actions.failure ?? "Herdr could not complete the request.")
            }
    }
}

private struct HerdrAgentContextMenu<Extra: View>: ViewModifier {
    let agents: [HerdrAgent]
    let store: HerdrStore
    let extra: Extra
    var onOpen: () -> Void = {}
    @State private var actions = HerdrAgentActions()
    @AppStorage(AppStorageKeys.Presenter.blurAgents, store: SharedDefaults.store)
    private var presenterBlurAgents = true

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if agents.count == 1, let agent = agents.first {
                    HerdrAgentMenu(agent: agent, store: store, actions: actions, onOpen: onOpen)
                } else {
                    ForEach(agents) { agent in
                        Menu(
                            PresenterState.shared.hidesAgents
                                ? agent.kind : agent.title
                        ) {
                            HerdrAgentMenu(
                                agent: agent, store: store, actions: actions, onOpen: onOpen)
                        }
                    }
                }
                if !agents.isEmpty, Extra.self != EmptyView.self { Divider() }
                extra
            }
            .modifier(HerdrAgentActionDialogs(actions: actions, store: store))
    }
}

extension View {
    func herdrAgentContextMenu(
        _ agent: HerdrAgent, store: HerdrStore, onOpen: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            HerdrAgentContextMenu(agents: [agent], store: store, extra: EmptyView(), onOpen: onOpen)
        )
    }

    func herdrAgentContextMenu<Extra: View>(
        agents: [HerdrAgent], store: HerdrStore, @ViewBuilder extra: () -> Extra
    ) -> some View {
        modifier(HerdrAgentContextMenu(agents: agents, store: store, extra: extra()))
    }
}
