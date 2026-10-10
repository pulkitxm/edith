import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

struct HerdrSpaceTerminalContext: Codable, Identifiable, Hashable {
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
    let id: UUID
    @ObservationIgnored var uiChanged: (@MainActor () -> Void)?
    private(set) var title: String
    var layout: WorkspaceLayout { didSet { uiChanged?() } }
    private var contents: [UUID: HerdrSpacePaneContent]

    init(agent: HerdrAgent, tab: HerdrOpenTab, context: HerdrSpaceTerminalContext?) {
        id = UUID()
        let target = (context ?? .local).target
        let placeholder = PaneTab(target: target, titleOverride: agent.title)
        let pane = PaneNode(tabs: [placeholder], selected: placeholder.id)
        title = agent.title
        layout = WorkspaceLayout(name: agent.workspace, root: .pane(pane), focused: pane.id)
        contents = [placeholder.id: .agent(tab)]
    }

    init(shellNumber: Int, context: HerdrSpaceTerminalContext) {
        id = UUID()
        let placeholder = PaneTab(
            target: context.target, titleOverride: "Shell \(shellNumber)")
        let pane = PaneNode(tabs: [placeholder], selected: placeholder.id)
        let title = "Shell \(shellNumber)"
        self.title = title
        layout = WorkspaceLayout(name: title, root: .pane(pane), focused: pane.id)
        contents = [placeholder.id: .terminal(TerminalSessionHolder())]
    }

    init(state: HerdrUISpaceTab, store: HerdrStore) {
        id = state.id
        title = state.title
        layout = state.layout
        contents = [:]
        adopt(state, store: store)
    }

    var uiState: HerdrUISpaceTab {
        var agents: [UUID: String] = [:]
        var views: [String: HerdrAgentView] = [:]
        for (id, content) in contents {
            if let tab = content.agent { agents[id] = tab.id; views[tab.id] = tab.view }
        }
        return .init(id: id, title: title, layout: layout, agents: agents, views: views)
    }

    func adopt(_ state: HerdrUISpaceTab, store: HerdrStore) {
        let callback = uiChanged
        uiChanged = nil
        defer { uiChanged = callback }
        let old = contents
        var next: [UUID: HerdrSpacePaneContent] = [:]
        for placeholder in state.layout.root.panes.flatMap(\.tabs) {
            if let id = state.agents[placeholder.id],
                let agent = store.projectionAgent(id) ?? old[placeholder.id]?.agent?.agent
            {
                var tab = old[placeholder.id]?.agent ?? store.makeTab(for: agent)
                tab.agent = agent
                tab.view = state.views[id] ?? .agent
                next[placeholder.id] = .agent(tab)
                HerdrAgentViews.set(tab.view, for: id, store.uiDefaults)
            } else {
                if case .terminal(let holder) = old[placeholder.id] {
                    next[placeholder.id] = .terminal(holder)
                } else {
                    next[placeholder.id] = .terminal(TerminalSessionHolder())
                }
            }
        }
        for (id, content) in old where next[id] == nil { content.stop() }
        contents = next
        title = state.title
        layout = state.layout
    }

    var paneCount: Int { layout.paneCount }

    var agentID: String? {
        for content in contents.values {
            if let id = content.agent?.id { return id }
        }
        return nil
    }

    var agentTab: HerdrOpenTab? {
        for content in contents.values {
            if let agent = content.agent { return agent }
        }
        return nil
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
        uiChanged?()
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

    func removeAgent(_ id: String) -> Bool {
        for pane in layout.root.panes {
            guard content(for: pane)?.agent?.id == id else { continue }
            for tab in pane.tabs { contents.removeValue(forKey: tab.id)?.stop() }
            guard layout.paneCount > 1 else { return false }
            layout.closePane(pane.id)
        }
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
        var result: [TerminalSessionHolder] = []
        result.reserveCapacity(contents.count)
        for content in contents.values { result.append(content.holder) }
        return result
    }

    private func refreshTitle() {
        for content in contents.values {
            guard let agent = content.agent else { continue }
            title = agent.agent.title
            return
        }
        title = "Terminal"
    }
}

@MainActor
@Observable
final class HerdrSpaceWindowModel {
    let spaceID: String
    let spaceTitle: String
    let contexts: [HerdrSpaceTerminalContext]
    @ObservationIgnored var uiChanged: (@MainActor () -> Void)?
    private(set) var tabs: [HerdrSpaceTabModel] {
        didSet { bindChanges(); uiChanged?() }
    }
    var selected: UUID? {
        didSet {
            defer { if selected != oldValue { uiChanged?() } }
            guard selected != oldValue, let agent = selectedTab?.agentTab?.agent else { return }
            usage.record(agent)
        }
    }
    private let usage: LauncherUsage
    private var shellNumber = 0

    init(space: HerdrAgentSpace, store: HerdrStore) {
        usage = store.usage
        spaceID = space.id
        spaceTitle = space.title
        contexts = HerdrSpaceTerminalContext.unique(for: space.agents)
        tabs = space.agents.map { agent in
            store.close(agent.id, rememberingPlacement: false)
            return HerdrSpaceTabModel(
                agent: agent, tab: store.makeTab(for: agent),
                context: HerdrSpaceTerminalContext.make(for: agent))
        }
        selected = tabs.first?.id
        if let agent = selectedTab?.agentTab?.agent { usage.record(agent) }
        if tabs.isEmpty { addTerminal() }
    }

    init(state: HerdrUISpace, store: HerdrStore) {
        spaceID = state.id
        spaceTitle = state.title
        contexts = state.contexts
        usage = store.usage
        tabs = state.tabs.map { HerdrSpaceTabModel(state: $0, store: store) }
        selected = state.selected
        shellNumber = tabs.count
        bindChanges()
    }

    func uiState(token: UUID) -> HerdrUISpace {
        .init(
            token: token, id: spaceID, title: spaceTitle, contexts: contexts,
            selected: selected, tabs: tabs.map(\.uiState))
    }

    func adopt(_ state: HerdrUISpace, store: HerdrStore) {
        let callback = uiChanged
        uiChanged = nil
        defer { uiChanged = callback }
        let old = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let ids = Set(state.tabs.map(\.id))
        for tab in tabs where !ids.contains(tab.id) { tab.stopAll() }
        tabs = state.tabs.map { record in
            let tab = old[record.id] ?? HerdrSpaceTabModel(state: record, store: store)
            tab.uiChanged = nil
            tab.adopt(record, store: store)
            return tab
        }
        selected = state.selected
        bindChanges()
        shellNumber = max(shellNumber, tabs.count)
    }

    private func bindChanges() {
        for tab in tabs { tab.uiChanged = { [weak self] in self?.uiChanged?() } }
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

    func removeAgent(_ id: String) {
        for tab in tabs.filter({ $0.agentID == id }) {
            if !tab.removeAgent(id) { tabs.removeAll { $0.id == tab.id } }
        }
        if !tabs.contains(where: { $0.id == selected }) { selected = tabs.first?.id }
    }

    @discardableResult
    func selectAgent(_ id: String) -> Bool {
        guard let tab = tabs.first(where: { $0.agentID == id }) else { return false }
        selected = tab.id
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
