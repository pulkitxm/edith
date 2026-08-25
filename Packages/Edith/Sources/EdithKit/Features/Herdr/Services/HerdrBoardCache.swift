import Foundation

public final class HerdrBoardCache: @unchecked Sendable {
    public let context: HerdrBoardContext
    private let lock = NSLock()
    private var labels: [String: String] = [:]
    private var tabLabels: [String: String] = [:]
    private var knownPanes = Set<String>()
    private var paneWorkspace: [String: String] = [:]
    private var paneTab: [String: String] = [:]
    private var agentsByPane: [String: HerdrAgent] = [:]

    public init(context: HerdrBoardContext) {
        self.context = context
    }

    public var agents: [HerdrAgent] {
        lock.lock()
        defer { lock.unlock() }
        return listed()
    }

    @discardableResult
    public func applySnapshot(_ text: String) -> [HerdrAgent] {
        lock.lock()
        defer { lock.unlock() }
        guard let board = HerdrListParser.snapshotBoard(from: text) else { return listed() }
        for (id, label) in board.labels { labels[id] = label }
        for (id, label) in board.tabLabels { tabLabels[id] = label }
        var records: [String: HerdrPaneRecord] = [:]
        for record in board.panes { records[record.pane] = record }
        for record in board.agents {
            records[record.pane] = records[record.pane]?.merging(record) ?? record
        }
        if board.hasPaneList {
            knownPanes = Set(board.panes.map(\.pane))
            knownPanes.formUnion(board.agents.map(\.pane))
        } else {
            knownPanes.formUnion(Set(records.keys))
        }
        var next: [String: HerdrAgent] = [:]
        var nextWorkspace: [String: String] = [:]
        var nextTab: [String: String] = [:]
        for pane in knownPanes {
            guard let record = records[pane] else {
                if let old = agentsByPane[pane] {
                    next[pane] = old
                    if let id = paneWorkspace[pane] { nextWorkspace[pane] = id }
                    if let id = paneTab[pane] { nextTab[pane] = id }
                }
                continue
            }
            if let id = record.workspaceID { nextWorkspace[pane] = id }
            if let id = record.tabID { nextTab[pane] = id }
            next[pane] = HerdrListParser.agent(
                from: record, context: context, workspaceLabels: labels, tabLabels: tabLabels,
                previous: agentsByPane[pane])
        }
        agentsByPane = next
        paneWorkspace = nextWorkspace
        paneTab = nextTab
        return listed()
    }

    @discardableResult
    public func applyEvent(_ text: String) -> [HerdrAgent] {
        lock.lock()
        defer { lock.unlock() }
        guard let name = HerdrListParser.eventName(in: text) else { return listed() }
        switch name {
        case "pane_created":
            if let record = HerdrListParser.eventPane(in: text) {
                knownPanes.insert(record.pane)
                upsert(record)
            }
        case "pane_updated":
            if let record = HerdrListParser.eventPane(in: text),
                knownPanes.contains(record.pane)
            {
                upsert(record)
            }
        case "pane_closed", "pane_exited":
            if let pane = HerdrListParser.eventPaneID(in: text) { remove(pane) }
        case "pane_moved":
            if let previous = HerdrListParser.eventPreviousPaneID(in: text) {
                remove(previous)
            }
            if let record = HerdrListParser.eventPane(in: text) {
                knownPanes.insert(record.pane)
                upsert(record)
            }
        case "pane_agent_detected":
            if let pane = HerdrListParser.eventPaneID(in: text), knownPanes.contains(pane) {
                var record =
                    HerdrListParser.eventPane(in: text)
                    ?? HerdrPaneRecord(
                        pane: pane, kindRaw: HerdrListParser.eventAgentKind(in: text))
                if record.kindRaw == nil {
                    record.kindRaw = HerdrListParser.eventAgentKind(in: text)
                }
                if HerdrListParser.eventReleased(in: text) {
                    record.statusRaw = HerdrListParser.eventFinalStatus(in: text) ?? "idle"
                }
                upsert(record)
            }
        case "tab_created", "tab_renamed":
            if let tab = HerdrListParser.eventTab(in: text), let label = tab.label {
                tabLabels[tab.id] = label
                relabelTabs()
            }
        case "tab_closed":
            if let tab = HerdrListParser.eventTab(in: text) { tabLabels[tab.id] = nil }
        case "workspace_created", "workspace_updated", "workspace_renamed":
            if let workspace = HerdrListParser.eventWorkspace(in: text) {
                if let label = workspace.label { labels[workspace.id] = label }
                relabel()
            }
        case "workspace_closed":
            if let workspace = HerdrListParser.eventWorkspace(in: text) {
                let panes = paneWorkspace.compactMap { $0.value == workspace.id ? $0.key : nil }
                for pane in panes { remove(pane) }
                labels[workspace.id] = nil
            }
        default:
            break
        }
        return listed()
    }

    private func upsert(_ record: HerdrPaneRecord) {
        if let id = record.workspaceID { paneWorkspace[record.pane] = id }
        if let id = record.tabID { paneTab[record.pane] = id }
        agentsByPane[record.pane] = HerdrListParser.agent(
            from: record, context: context, workspaceLabels: labels, tabLabels: tabLabels,
            previous: agentsByPane[record.pane])
    }

    private func remove(_ pane: String) {
        knownPanes.remove(pane)
        agentsByPane[pane] = nil
        paneWorkspace[pane] = nil
        paneTab[pane] = nil
    }

    private func relabel() {
        for pane in agentsByPane.keys {
            if let id = paneWorkspace[pane], let label = labels[id] {
                agentsByPane[pane]?.workspace = label
            }
        }
    }

    private func relabelTabs() {
        for pane in agentsByPane.keys {
            guard let agent = agentsByPane[pane], agent.category == .terminal else { continue }
            guard let id = paneTab[pane], let label = tabLabels[id], !label.isEmpty else {
                continue
            }
            agentsByPane[pane]?.title = label
        }
    }

    public var terminalPanes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return agentsByPane.values.filter { $0.category == .terminal }.map(\.pane).sorted()
    }

    @discardableResult
    public func applyProcessNames(_ names: [String: String]) -> [HerdrAgent] {
        lock.lock()
        defer { lock.unlock() }
        for (pane, name) in names where !name.isEmpty {
            guard agentsByPane[pane] != nil else { continue }
            agentsByPane[pane]?.process = name
        }
        return listed()
    }

    private func listed() -> [HerdrAgent] {
        agentsByPane.values.sorted { $0.pane < $1.pane }
    }
}
