import AppKit
import EdithKit
import Observation
import SwiftTerm
import SwiftUI

@MainActor
@Observable
final class HerdrStore {
    static let boardID = "board"

    var hosts: [HerdrHostSnapshot] = []
    var machineFilter = "all"
    var kindFilter: Set<String> = []
    var selectedTab = boardID
    var tabs: [HerdrOpenTab] = []
    var refreshing = false
    var copiedID: String?
    var detailOpen = true

    private var connections: [UUID: SSHConnection] = [:]

    var agents: [HerdrAgent] { hosts.flatMap(\.agents) }

    var machineChoices: [(id: String, name: String)] {
        [("all", "All machines"), ("local", "This Mac")]
            + hosts.filter { !$0.isLocal }.map { ($0.id, $0.name) }
    }

    var kindChoices: [String] {
        var labels = HerdrKind.filterLabels
        for kind in Set(agents.map(\.kind)).sorted() where !labels.contains(kind) {
            labels.append(kind)
        }
        return labels
    }

    var filteredAgents: [HerdrAgent] {
        agents.filter { agent in
            switch machineFilter {
            case "all": break
            case "local":
                if !agent.machineIsLocal { return false }
            default:
                if agent.machineID != machineFilter { return false }
            }
            if !kindFilter.isEmpty, !kindFilter.contains(agent.kind) { return false }
            return true
        }
    }

    func kindIsSelected(_ id: String) -> Bool {
        id == "all" ? kindFilter.isEmpty : kindFilter.contains(id)
    }

    func selectKind(_ id: String) {
        selectKind(id, exclusive: NSEvent.modifierFlags.contains(.command))
    }

    func selectKind(_ id: String, exclusive: Bool) {
        if id == "all" {
            kindFilter = []
            return
        }
        if exclusive {
            kindFilter = [id]
            return
        }
        if kindFilter.contains(id) {
            kindFilter.remove(id)
        } else {
            kindFilter.insert(id)
        }
    }

    var columns: [HerdrAgentStatus] { HerdrAgentStatus.allCases }

    var openIDs: Set<String> { Set(tabs.map(\.id)) }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let snapshots = await HerdrCollector.collect(.all)
        hosts = snapshots
        for index in tabs.indices {
            if let updated = agents.first(where: { $0.id == tabs[index].id }) {
                tabs[index].agent = updated
            }
        }
        refreshing = false
    }

    func open(_ agent: HerdrAgent) {
        if tabs.contains(where: { $0.id == agent.id }) {
            selectedTab = agent.id
            return
        }
        let machine: Machine? =
            agent.machineIsLocal
            ? nil
            : MachineRegistry.machines().first { $0.id.uuidString == agent.machineID }
        tabs.append(HerdrOpenTab(agent: agent, machine: machine, holder: TerminalSessionHolder()))
        selectedTab = agent.id
    }

    func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].holder.stop()
        tabs.remove(at: index)
        if selectedTab == id {
            selectedTab = tabs.last?.id ?? Self.boardID
        }
    }

    func selectBoard() {
        selectedTab = Self.boardID
    }

    func connection(for machine: Machine) async throws -> SSHConnection {
        if let existing = connections[machine.id] {
            try await existing.connect()
            return existing
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        connections[machine.id] = connection
        return connection
    }

    func copyAttachCommand(for agent: HerdrAgent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HerdrAttachCommand.line(for: agent), forType: .string)
        copiedID = agent.id
        let id = agent.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == id { copiedID = nil }
        }
    }
}

struct HerdrOpenTab: Identifiable {
    var id: String { agent.id }
    var agent: HerdrAgent
    var machine: Machine?
    let holder: TerminalSessionHolder
}
