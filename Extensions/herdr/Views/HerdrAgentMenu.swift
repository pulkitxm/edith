import EdithExtensionAccounts
import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HerdrAgentActions {
    var agentToDelete: HerdrAgent?
    var pendingRestart: HerdrAgentRestartChoice?
    var failure: String?
    private(set) var deleting: Set<String> = []
    private(set) var openingTerminal: Set<String> = []
    private(set) var restarting: Set<String> = []

    func open(_ agent: HerdrAgent, store: HerdrStore) {
        if store.raiseSpace(containingAgent: agent.id) { return }
        if store.raiseAgentWindow(agent.id) { return }
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
        if store.uiClient == nil {
            HerdrSpaceWindow.removeAgent(agent.id)
            store.close(agent.id, rememberingPlacement: false)
        }
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

    func restart(_ choice: HerdrAgentRestartChoice, store: HerdrStore) async {
        let agent = choice.agent
        guard restarting.insert(agent.id).inserted else { return }
        defer { restarting.remove(agent.id) }
        do {
            try await store.restartAgent(agent, kind: choice.kind, accountID: choice.accountID)
            HerdrSpaceWindow.removeAgent(agent.id)
            HerdrAgentWindow.close(agent.id)
            store.reattach(agent.id)
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

struct HerdrAgentRestartChoice: Identifiable {
    let agent: HerdrAgent
    var kind: String?
    var accountID: String?
    var title: String

    var id: String { agent.id }
}

@MainActor
enum HerdrAgentRestartMenu {
    static func items(
        for agent: HerdrAgent, store: HerdrStore, actions: HerdrAgentActions
    ) -> [EdithMenuItem] {
        let accounts = store.claudeAccounts.launchAccounts.filter {
            agent.machineIsLocal
                ? $0.remoteMachineID == nil
                : $0.remoteMachineID == nil || $0.remoteMachineID == agent.machineID
        }
        let activeAccount = store.accountSessions[agent.id]
        func choose(accountID: String, name: String) {
            actions.pendingRestart = HerdrAgentRestartChoice(
                agent: agent, accountID: accountID, title: "resume in \(name)")
        }
        return EdithMenu.items {
            EdithMenuItem.button("Restart Agent…") {
                actions.pendingRestart = HerdrAgentRestartChoice(
                    agent: agent, title: "resume in \(HerdrKind.displayName(for: agent.kind))")
            }
            if HerdrAgentMenu.isClaude(agent) {
                EdithMenuItem.menu("Restart in Account") {
                    EdithMenuItem.button("Existing CLI Login") {
                        choose(accountID: "cli", name: "the CLI login")
                    }
                    for account in accounts {
                        EdithMenuItem.button(
                            account.name, enabled: activeAccount != account.id.uuidString
                        ) {
                            choose(accountID: account.id.uuidString, name: account.name)
                        }
                    }
                }
            }
            EdithMenuItem.menu("Continue in Agent") {
                for kind in AgentResume.handoffTargets(from: agent.kind) {
                    EdithMenuItem.button(kind) {
                        actions.pendingRestart = HerdrAgentRestartChoice(
                            agent: agent, kind: kind, title: "continue in \(kind)")
                    }
                }
            }
        }
    }
}

@MainActor
enum HerdrBroadcastMenu {
    static func items(
        agents: [HerdrAgent], store: HerdrStore, scopeTitle: String? = nil,
        redactScope: Bool = false
    ) -> [EdithMenuItem] {
        HerdrBroadcastGroup.allCases.map { group in
            let count = group.recipients(from: agents).count
            return EdithMenuItem.button("\(group.title) (\(count))", enabled: count > 0) {
                store.messaging.compose(
                    group, from: agents, scopeTitle: scopeTitle, redactScope: redactScope)
            }
        }
    }
}

@MainActor
enum HerdrAgentMenu {
    static func isClaude(_ agent: HerdrAgent) -> Bool {
        HerdrKind.displayName(for: agent.kind) == "Claude Code"
    }

    static func refreshAccounts(for agents: [HerdrAgent], store: HerdrStore) {
        guard agents.contains(where: isClaude) else { return }
        Task { await store.claudeAccounts.read() }
    }

    static func items(
        for agents: [HerdrAgent], store: HerdrStore, actions: HerdrAgentActions,
        launchEnabled: Bool, onOpen: @escaping @MainActor () -> Void = {},
        extra: [EdithMenuItem] = []
    ) -> [EdithMenuItem] {
        let hideAgents = PresenterState.shared.hidesAgents
        return EdithMenu.items {
            if agents.count == 1, let agent = agents.first {
                items(
                    for: agent, store: store, actions: actions, launchEnabled: launchEnabled,
                    onOpen: onOpen)
            } else {
                for agent in agents {
                    EdithMenuItem.menu(hideAgents ? agent.kind : agent.title) {
                        items(
                            for: agent, store: store, actions: actions,
                            launchEnabled: launchEnabled, onOpen: onOpen)
                    }
                }
            }
            EdithMenuItem.separator
            extra
        }
    }

    static func items(
        for agent: HerdrAgent, store: HerdrStore, actions: HerdrAgentActions,
        launchEnabled: Bool, onOpen: @escaping @MainActor () -> Void = {}
    ) -> [EdithMenuItem] {
        let hideAgents = PresenterState.shared.hidesAgents
        let destinations = store.tabs.filter { !$0.layout.contains(agent.id) }
        func openBeside(_ tab: HerdrTab, _ side: InsertSide) {
            onOpen()
            actions.openBeside(agent, store: store, tabID: tab.id, side: side)
        }
        return EdithMenu.items {
            EdithMenuItem.button("Open") {
                onOpen()
                actions.open(agent, store: store)
            }
            EdithMenuItem.menu("Open In") {
                EdithMenuItem.button("New Tab") {
                    onOpen()
                    actions.openInNewTab(agent, store: store)
                }
                EdithMenuItem.button("New Window") {
                    onOpen()
                    actions.openInNewWindow(agent, store: store, launchEnabled: launchEnabled)
                }
                EdithMenuItem.separator
                for tab in destinations {
                    EdithMenuItem.menu(
                        "Beside \(tabTitle(tab, store: store, hideAgents: hideAgents))"
                    ) {
                        EdithMenuItem.button("Right") { openBeside(tab, .right) }
                        EdithMenuItem.button("Left") { openBeside(tab, .left) }
                        EdithMenuItem.button("Below") { openBeside(tab, .bottom) }
                        EdithMenuItem.button("Above") { openBeside(tab, .top) }
                    }
                }
            }
            if !agent.isTerminal {
                EdithMenuItem.button(
                    "Open in Herdr Terminal", enabled: !actions.openingTerminal.contains(agent.id)
                ) {
                    HerdrWorkOwnership.start {
                        await actions.openInHerdrTerminal(agent, store: store)
                        if actions.failure == nil { onOpen() }
                    }
                }
            }
            EdithMenuItem.button(
                store.copiedID == agent.id ? "Copied Open Command" : "Copy Open Command"
            ) {
                store.copyAttachCommand(for: agent)
            }
            if !agent.isTerminal {
                EdithMenuItem.separator
                EdithMenuItem.button("Send Message…") {
                    onOpen()
                    let detached =
                        store.raiseSpace(containingAgent: agent.id)
                        || store.raiseAgentWindow(agent.id)
                    store.messaging.compose(to: agent, presenterID: detached ? agent.id : nil)
                    if !detached { store.revealWorkspaceWindow() }
                }
                cancelWaiting(agent, store: store)
                if AgentResume.profile(for: agent.kind) != nil {
                    EdithMenuItem.separator
                    HerdrAgentRestartMenu.items(for: agent, store: store, actions: actions)
                        .disabled(actions.restarting.contains(agent.id))
                }
                EdithMenuItem.separator
                EdithMenuItem.button(
                    "Delete Agent…", enabled: !actions.deleting.contains(agent.id)
                ) {
                    actions.agentToDelete = agent
                }
            }
        }
    }

    private static func cancelWaiting(_ agent: HerdrAgent, store: HerdrStore) -> [EdithMenuItem] {
        let waiting = store.messaging.armedHooks(for: agent.id)
        return EdithMenu.items {
            if waiting.count == 1, let hook = waiting.first {
                EdithMenuItem.button(
                    "Cancel Waiting Message", enabled: hook.phase != .sending,
                    help: hook.schedule.sendsPhrase(now: Date())
                ) {
                    HerdrWorkOwnership.start { await store.messaging.remove(hook.id) }
                }
            } else if waiting.count > 1 {
                EdithMenuItem.menu("Cancel Waiting Message") {
                    for hook in waiting {
                        EdithMenuItem.button(cancelTitle(hook), enabled: hook.phase != .sending) {
                            HerdrWorkOwnership.start { await store.messaging.remove(hook.id) }
                        }
                    }
                }
            }
        }
    }

    private static func cancelTitle(_ hook: HerdrAgentHook) -> String {
        let phrase = hook.schedule.sendsPhrase(now: Date())
        let message =
            hook.message.count > 28
            ? "\(hook.message.prefix(28))…" : hook.message
        return "\(phrase): \(message)"
    }

    static func tabTitle(_ tab: HerdrTab, store: HerdrStore, hideAgents: Bool) -> String {
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
            .confirmationDialog(
                "Restart this agent?",
                isPresented: Binding(
                    get: { actions.pendingRestart != nil },
                    set: { if !$0 { actions.pendingRestart = nil } }),
                titleVisibility: .visible, presenting: actions.pendingRestart
            ) { choice in
                Button("Restart") {
                    HerdrWorkOwnership.start { await actions.restart(choice, store: store) }
                }
                Button("Cancel", role: .cancel) { actions.pendingRestart = nil }
            } message: { choice in
                Text("\(choice.agent.title) will quit and \(choice.title). Any running turn stops.")
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

private struct HerdrAgentContextMenu: ViewModifier {
    let agents: [HerdrAgent]
    let store: HerdrStore
    let extra: @MainActor () -> [EdithMenuItem]
    var onOpen: @MainActor () -> Void = {}
    @State private var actions = HerdrAgentActions()
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    func body(content: Content) -> some View {
        let agents = agents
        let store = store
        let extra = extra
        let onOpen = onOpen
        let actions = actions
        let launchEnabled = launchEnabled
        return
            content
            .edithContextMenu {
                HerdrAgentMenu.refreshAccounts(for: agents, store: store)
                return HerdrAgentMenu.items(
                    for: agents, store: store, actions: actions, launchEnabled: launchEnabled,
                    onOpen: onOpen, extra: extra())
            }
            .modifier(HerdrAgentActionDialogs(actions: actions, store: store))
    }
}

extension View {
    func herdrAgentContextMenu(
        _ agent: HerdrAgent, store: HerdrStore, onOpen: @escaping @MainActor () -> Void = {}
    ) -> some View {
        modifier(
            HerdrAgentContextMenu(agents: [agent], store: store, extra: { [] }, onOpen: onOpen))
    }

    func herdrAgentContextMenu(
        agents: [HerdrAgent], store: HerdrStore,
        extra: @escaping @MainActor () -> [EdithMenuItem] = { [] }
    ) -> some View {
        modifier(HerdrAgentContextMenu(agents: agents, store: store, extra: extra))
    }
}
