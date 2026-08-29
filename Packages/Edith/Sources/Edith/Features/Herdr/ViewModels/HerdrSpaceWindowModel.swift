import EdithKit
import Foundation
import Observation

struct HerdrSpaceTerminalContext: Identifiable, Hashable {
    let machineID: UUID
    let machineName: String
    let workingDirectory: String?

    var id: String {
        "\(machineID.uuidString)|\(workingDirectory ?? "")"
    }

    var target: PaneTarget {
        PaneTarget(machineID: machineID, screen: .terminal, argument: workingDirectory)
    }

    var title: String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return machineName }
        return "\(machineName) · \(workingDirectory)"
    }

    static func make(for agent: HerdrAgent) -> HerdrSpaceTerminalContext? {
        let machineID: UUID
        if agent.machineIsLocal {
            machineID = Machine.localID
        } else if let parsed = UUID(uuidString: agent.machineID) {
            machineID = parsed
        } else {
            return nil
        }
        let directory = agent.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return HerdrSpaceTerminalContext(
            machineID: machineID, machineName: agent.machineName,
            workingDirectory: directory.isEmpty ? nil : directory)
    }

    static func unique(for agents: [HerdrAgent]) -> [HerdrSpaceTerminalContext] {
        var seen = Set<String>()
        return agents.compactMap(make).filter { seen.insert($0.id).inserted }
    }

    static let local = HerdrSpaceTerminalContext(
        machineID: Machine.localID, machineName: "This Mac", workingDirectory: nil)
}

enum HerdrSpacePaneContent {
    case agent(HerdrOpenTab)
    case terminal(TerminalSessionHolder)

    var agent: HerdrOpenTab? {
        guard case let .agent(tab) = self else { return nil }
        return tab
    }

    var holder: TerminalSessionHolder {
        switch self {
        case let .agent(tab): tab.holder
        case let .terminal(holder): holder
        }
    }

    @MainActor
    func stop() {
        holder.stop()
        if case let .agent(tab) = self { tab.quinjet.stop() }
    }
}

@MainActor
@Observable
final class HerdrSpaceTabModel: Identifiable {
    let id = UUID()
    private(set) var title: String
    var layout: WorkspaceLayout
    private var contents: [UUID: HerdrSpacePaneContent]

    init(agent: HerdrAgent, tab: HerdrOpenTab, context: HerdrSpaceTerminalContext?) {
        let target = (context ?? .local).target
        let placeholder = PaneTab(target: target, titleOverride: agent.title)
        let pane = PaneNode(tabs: [placeholder], selected: placeholder.id)
        title = agent.title
        layout = WorkspaceLayout(name: agent.workspace, root: .pane(pane), focused: pane.id)
        contents = [placeholder.id: .agent(tab)]
    }

    init(shellNumber: Int, context: HerdrSpaceTerminalContext) {
        let placeholder = PaneTab(
            target: context.target, titleOverride: "Shell \(shellNumber)")
        let pane = PaneNode(tabs: [placeholder], selected: placeholder.id)
        let title = "Shell \(shellNumber)"
        self.title = title
        layout = WorkspaceLayout(name: title, root: .pane(pane), focused: pane.id)
        contents = [placeholder.id: .terminal(TerminalSessionHolder())]
    }

    var paneCount: Int { layout.paneCount }

    var agentID: String? {
        contents.values.compactMap { $0.agent?.id }.first
    }

    var focusedPane: PaneNode? {
        layout.root.pane(layout.focused) ?? layout.root.panes.first
    }

    var focusedTarget: PaneTarget? {
        guard let pane = focusedPane else { return nil }
        return pane.tabs.first { $0.id == pane.selected }?.target ?? pane.tabs.first?.target
    }

    func content(for pane: PaneNode) -> HerdrSpacePaneContent? {
        let selected = pane.tabs.first { $0.id == pane.selected } ?? pane.tabs.first
        guard let selected else { return nil }
        return contents[selected.id]
    }

    func focus(_ paneID: UUID) {
        guard layout.root.pane(paneID) != nil else { return }
        layout.focused = paneID
    }

    func setAgentView(_ view: HerdrAgentView, defaults: UserDefaults = SharedDefaults.store) {
        guard
            let entry = contents.first(where: { $0.value.agent != nil }),
            var tab = entry.value.agent
        else { return }
        guard tab.view != view else { return }
        tab.view = view
        contents[entry.key] = .agent(tab)
        HerdrAgentViews.set(view, for: tab.id, defaults)
    }

    func split(_ side: InsertSide) {
        guard let pane = focusedPane, let target = focusedTarget else { return }
        let placeholder = PaneTab(target: target)
        let inserted = PaneNode(tabs: [placeholder], selected: placeholder.id)
        layout.root.insert(.pane(inserted), near: pane.id, side: side)
        layout.focused = inserted.id
        contents[placeholder.id] = .terminal(TerminalSessionHolder())
    }

    @discardableResult
    func closeFocusedPane() -> Bool {
        guard layout.paneCount > 1, let pane = focusedPane else { return false }
        for tab in pane.tabs {
            contents.removeValue(forKey: tab.id)?.stop()
        }
        layout.closePane(pane.id)
        refreshTitle()
        return true
    }

    @discardableResult
    func cyclePane(backwards: Bool) -> Bool {
        let panes = layout.root.panes
        guard panes.count > 1 else { return false }
        let current = panes.firstIndex { $0.id == layout.focused } ?? 0
        let next =
            backwards
            ? (current - 1 + panes.count) % panes.count
            : (current + 1) % panes.count
        layout.focused = panes[next].id
        return true
    }

    func equalize() {
        layout.root.equalize()
    }

    func resize(splitID: UUID, index: Int, change: Double) {
        layout.root.updateSplit(splitID) { node in
            guard index + 1 < node.ratios.count else { return }
            let first = node.ratios[index] + change
            let second = node.ratios[index + 1] - change
            guard first >= 0.08, second >= 0.08 else { return }
            node.ratios[index] = first
            node.ratios[index + 1] = second
        }
    }

    func stopAll() {
        for content in contents.values { content.stop() }
        contents = [:]
    }

    var holders: [TerminalSessionHolder] {
        contents.values.map(\.holder)
    }

    private func refreshTitle() {
        if let agent = contents.values.compactMap({ $0.agent }).first {
            title = agent.agent.title
        }
    }
}

@MainActor
@Observable
final class HerdrSpaceWindowModel {
    let spaceID: String
    let spaceTitle: String
    let contexts: [HerdrSpaceTerminalContext]
    private(set) var tabs: [HerdrSpaceTabModel]
    var selected: UUID?
    private var shellNumber = 0

    init(space: HerdrAgentSpace, store: HerdrStore) {
        spaceID = space.id
        spaceTitle = space.title
        contexts = HerdrSpaceTerminalContext.unique(for: space.agents)
        tabs = space.agents.map { agent in
            store.close(agent.id)
            return HerdrSpaceTabModel(
                agent: agent, tab: store.makeTab(for: agent),
                context: HerdrSpaceTerminalContext.make(for: agent))
        }
        selected = tabs.first?.id
        if tabs.isEmpty { addTerminal() }
    }

    var selectedTab: HerdrSpaceTabModel? {
        tabs.first { $0.id == selected } ?? tabs.first
    }

    var selectedIndex: Int? {
        guard let selectedTab else { return nil }
        return tabs.firstIndex { $0.id == selectedTab.id }
    }

    var selectedAgentID: String? { selectedTab?.agentID }

    var selectedContext: HerdrSpaceTerminalContext {
        guard let target = selectedTab?.focusedTarget else {
            return contexts.first ?? .local
        }
        return contexts.first {
            $0.machineID == target.machineID && $0.workingDirectory == target.argument
        }
            ?? HerdrSpaceTerminalContext(
                machineID: target.machineID,
                machineName: contextName(for: target.machineID),
                workingDirectory: target.argument)
    }

    @discardableResult
    func addTerminal(context: HerdrSpaceTerminalContext? = nil) -> HerdrSpaceTabModel {
        shellNumber += 1
        let tab = HerdrSpaceTabModel(
            shellNumber: shellNumber, context: context ?? selectedContext)
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func split(_ side: InsertSide) {
        selectedTab?.split(side)
    }

    @discardableResult
    func closeFocusedPane() -> Bool {
        selectedTab?.closeFocusedPane() ?? false
    }

    @discardableResult
    func closeSelectedTab() -> Bool {
        guard tabs.count > 1, let index = selectedIndex else { return false }
        tabs[index].stopAll()
        tabs.remove(at: index)
        selected = tabs[min(index, tabs.count - 1)].id
        return true
    }

    @discardableResult
    func cycleTab(backwards: Bool) -> Bool {
        guard tabs.count > 1, let index = selectedIndex else { return false }
        let next =
            backwards
            ? (index - 1 + tabs.count) % tabs.count : (index + 1) % tabs.count
        selected = tabs[next].id
        return true
    }

    @discardableResult
    func cyclePane(backwards: Bool) -> Bool {
        selectedTab?.cyclePane(backwards: backwards) ?? false
    }

    @discardableResult
    func selectTab(number: Int) -> Bool {
        guard number >= 1, number <= 9, !tabs.isEmpty else { return false }
        selected = tabs[min(number - 1, tabs.count - 1)].id
        return true
    }

    func stopAll() {
        for tab in tabs { tab.stopAll() }
        tabs = []
        selected = nil
    }

    private func contextName(for machineID: UUID) -> String {
        contexts.first { $0.machineID == machineID }?.machineName
            ?? (machineID == Machine.localID ? "This Mac" : "Machine")
    }
}
