import AppKit
import EdithKit
import Observation
import SwiftUI

struct HerdrPanelHost: Equatable {
    let machineID: String
    let machineName: String
    let isLocal: Bool
    let sshTarget: String?
    let machine: Machine?

    static let local = HerdrPanelHost(
        machineID: HerdrHostSnapshot.localID, machineName: "This Mac", isLocal: true,
        sshTarget: nil, machine: nil)

    init(
        machineID: String, machineName: String, isLocal: Bool, sshTarget: String?,
        machine: Machine?
    ) {
        self.machineID = machineID
        self.machineName = machineName
        self.isLocal = isLocal
        self.sshTarget = sshTarget
        self.machine = machine
    }

    init(_ tab: HerdrOpenTab) {
        self.init(
            machineID: tab.agent.machineID, machineName: tab.agent.machineName,
            isLocal: tab.agent.machineIsLocal, sshTarget: tab.agent.sshTarget,
            machine: tab.machine)
    }
}

struct HerdrTerminalOrigin: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String?
    let host: HerdrPanelHost
    let cwd: String?

    static let home = "~"
    static let local = HerdrTerminalOrigin(
        id: HerdrHostSnapshot.localID, title: "This Mac", kind: nil, host: .local, cwd: home)

    init(id: String, title: String, kind: String?, host: HerdrPanelHost, cwd: String?) {
        self.id = id
        self.title = title
        self.kind = kind
        self.host = host
        self.cwd = cwd
    }

    init(_ tab: HerdrOpenTab, startFolder: HerdrTerminalSettings.StartFolder) {
        let cwd = tab.agent.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesFolder = startFolder == .agent && !tab.agent.isTerminal && !cwd.isEmpty
        self.init(
            id: tab.agent.id, title: tab.agent.title,
            kind: tab.agent.isTerminal ? nil : tab.agent.kind, host: HerdrPanelHost(tab),
            cwd: usesFolder ? cwd : Self.home)
    }

    var location: String {
        HerdrPanelTerminal.location(cwd: cwd, host: host)
    }
}

struct HerdrPanelTerminal: Identifiable {
    let id: String
    let host: HerdrPanelHost
    let session: String
    let cwd: String?
    let holder: TerminalSessionHolder
    var pane: String?
    var process: HerdrPaneProcess?
    var failure: String?

    var title: String {
        if let process { return process.name }
        return pane == nil ? "Starting" : "Terminal"
    }

    var running: Bool { process?.running == true }

    var location: String {
        Self.location(cwd: cwd, host: host)
    }

    static func location(cwd: String?, host: HerdrPanelHost) -> String {
        let folder = cwd.map { ($0 as NSString).lastPathComponent } ?? HerdrTerminalOrigin.home
        return host.isLocal ? folder : "\(folder) · \(host.machineName)"
    }

    var bridgeAgent: HerdrAgent? {
        guard let pane else { return nil }
        return HerdrAgent.make(
            machineID: host.machineID, machineName: host.machineName,
            machineIsLocal: host.isLocal, sshTarget: host.sshTarget, session: session, pane: pane,
            kind: HerdrKind.terminalLabel, status: .unknown, title: title,
            workspace: HerdrTerminalSpace.label, cwd: cwd ?? "")
    }
}

struct HerdrTerminalPanel: Equatable {
    var terminalIDs: [String] = []
    var selectedID: String?
    var open = false
}

struct HerdrTerminalCloseRequest: Identifiable {
    let id = UUID()
    let running: [String]
    let proceed: @MainActor () -> Void

    var message: String {
        let names = running.joined(separator: ", ")
        return running.count == 1
            ? "\(names) is still running in this tab's terminal. Closing the tab stops it."
            : "\(names) are still running in this tab's terminals. Closing the tab stops them."
    }
}

struct HerdrPanelTerminalOperations: Sendable {
    var open:
        @Sendable (_ session: String, _ cwd: String?, _ machine: Machine?) async throws ->
            HerdrCreatedPane
    var state:
        @Sendable (_ session: String, _ pane: String, _ machine: Machine?) async throws ->
            HerdrPaneState
    var close:
        @Sendable (_ session: String, _ pane: String, _ machine: Machine?) async throws -> Void
    var run:
        @Sendable (_ session: String, _ pane: String, _ command: String, _ machine: Machine?)
            async throws -> Void

    static let live = HerdrPanelTerminalOperations(
        open: { try await HerdrTerminalSpace.openTerminal(session: $0, cwd: $1, on: $2) },
        state: { try await HerdrPaneOperations.state(session: $0, pane: $1, on: $2) },
        close: { try await HerdrPaneOperations.close(session: $0, pane: $1, on: $2) },
        run: { try await HerdrPaneOperations.run(session: $0, pane: $1, command: $2, on: $3) })
}

enum HerdrTerminalPanelSizing {
    static let heightDefault = 260.0
    static let heightMinimum = 120.0
    static let listWidth = 184.0
    static let refreshInterval = Duration.seconds(2)

    static func height(_ value: Double, maximum: Double) -> Double {
        min(max(heightMinimum, maximum), max(heightMinimum, value))
    }
}

enum HerdrTerminalPanelKey: Equatable {
    case toggle
    case visibility
    case new

    static func resolve(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> HerdrTerminalPanelKey? {
        let flags = modifiers.chordOnly
        if keyCode == 50, flags == .control { return .toggle }
        if keyCode == 50, flags == [.control, .shift] { return .new }
        if flags == .command, characters?.lowercased() == "j" { return .visibility }
        return nil
    }
}

enum HerdrTerminalOwnership {
    static func moves(
        owners: [String], previous: [HerdrTab], current: [HerdrTab], fallback: String
    ) -> [(owner: String, destination: String)] {
        var live = Set<String>()
        for tab in current { live.insert(tab.id) }
        var result: [(owner: String, destination: String)] = []
        for owner in owners where owner != fallback && !live.contains(owner) {
            let before = previous.first { $0.id == owner }
            var candidates: [String] = []
            if let before { candidates = [before.focused] + before.agentIDs }
            let destination = candidates.lazy.compactMap { agentID in
                current.first { $0.layout.contains(agentID) }?.id
            }.first
            result.append((owner, destination ?? fallback))
        }
        return result
    }
}

@MainActor
@Observable
final class HerdrTerminalPanels {
    private(set) var panels: [String: HerdrTerminalPanel] = [:]
    private(set) var terminals: [String: HerdrPanelTerminal] = [:]
    private(set) var focusedOwner: String?
    var maximized = false
    var closeRequest: HerdrTerminalCloseRequest?
    var height = HerdrTerminalPanelSizing.heightDefault {
        didSet {
            guard height != oldValue else { return }
            defaults.set(height, forKey: AppStorageKeys.Herdr.terminalPanelHeight)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let operations: HerdrPanelTerminalOperations
    @ObservationIgnored private let session: String
    @ObservationIgnored private var confirming = Set<String>()

    init(
        defaults: UserDefaults = SharedDefaults.store,
        operations: HerdrPanelTerminalOperations = .live,
        session: String = HerdrTerminalSpace.defaultSession
    ) {
        self.defaults = defaults
        self.operations = operations
        self.session = session
        height =
            defaults.object(forKey: AppStorageKeys.Herdr.terminalPanelHeight) as? Double
            ?? HerdrTerminalPanelSizing.heightDefault
    }

    var isEmpty: Bool { panels.isEmpty }

    func isOpen(_ owner: String) -> Bool {
        panels[owner]?.open == true
    }

    func holdsFocus(_ owner: String) -> Bool {
        focusedOwner == owner && isOpen(owner)
    }

    func terminals(of owner: String) -> [HerdrPanelTerminal] {
        var result: [HerdrPanelTerminal] = []
        for id in panels[owner]?.terminalIDs ?? [] {
            if let terminal = terminals[id] { result.append(terminal) }
        }
        return result
    }

    func selectedID(in owner: String) -> String? {
        panels[owner]?.selectedID
    }

    func toggle(_ owner: String, host: HerdrPanelHost, cwd: String?) {
        guard isOpen(owner) else {
            show(owner, host: host, cwd: cwd)
            return
        }
        if focusedOwner == owner {
            hide(owner)
        } else {
            focusedOwner = owner
        }
    }

    func toggleVisibility(_ owner: String, host: HerdrPanelHost, cwd: String?) {
        if isOpen(owner) {
            hide(owner)
        } else {
            show(owner, host: host, cwd: cwd)
        }
    }

    func show(_ owner: String, host: HerdrPanelHost, cwd: String?) {
        guard let panel = panels[owner], !panel.terminalIDs.isEmpty else {
            newTerminal(in: owner, host: host, cwd: cwd)
            return
        }
        panels[owner]?.open = true
        focusedOwner = owner
    }

    func hide(_ owner: String) {
        panels[owner]?.open = false
        if focusedOwner == owner { focusedOwner = nil }
    }

    func focus(_ owner: String) {
        guard focusedOwner != owner else { return }
        focusedOwner = owner
    }

    func releaseFocus() {
        guard focusedOwner != nil else { return }
        focusedOwner = nil
    }

    func select(_ id: String, in owner: String) {
        guard panels[owner]?.terminalIDs.contains(id) == true else { return }
        panels[owner]?.selectedID = id
        focusedOwner = owner
    }

    @discardableResult
    func newTerminal(in owner: String, host: HerdrPanelHost, cwd: String?) -> String {
        let id = UUID().uuidString
        terminals[id] = HerdrPanelTerminal(
            id: id, host: host, session: session, cwd: cwd, holder: TerminalSessionHolder())
        var panel = panels[owner] ?? HerdrTerminalPanel()
        panel.terminalIDs.append(id)
        panel.selectedID = id
        panel.open = true
        panels[owner] = panel
        focusedOwner = owner
        Task { await create(id) }
        return id
    }

    func retry(_ id: String) {
        guard let terminal = terminals[id], terminal.failure != nil else { return }
        terminals[id]?.failure = nil
        guard terminal.pane == nil else { return }
        Task { await create(id) }
    }

    func fail(_ id: String, _ message: String) {
        terminals[id]?.failure = message
    }

    private func create(_ id: String) async {
        guard let terminal = terminals[id] else { return }
        let machine = terminal.host.machine
        guard terminal.host.isLocal || machine != nil else {
            fail(id, HerdrQuinjetError.machineUnavailable.localizedDescription)
            return
        }
        do {
            let created = try await operations.open(terminal.session, terminal.cwd, machine)
            guard terminals[id] != nil else {
                try? await operations.close(terminal.session, created.paneID, machine)
                return
            }
            terminals[id]?.pane = created.paneID
            let command = HerdrTerminalSettings.load(defaults).startupCommand
            if !command.isEmpty {
                try? await operations.run(terminal.session, created.paneID, command, machine)
            }
            await refresh(ids: [id])
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    func close(_ id: String) {
        guard let terminal = remove(id) else { return }
        terminal.holder.stop()
        dispose(terminal)
    }

    func closeAll(owners: [String]) {
        for owner in owners {
            guard let panel = panels.removeValue(forKey: owner) else { continue }
            if focusedOwner == owner { focusedOwner = nil }
            for id in panel.terminalIDs {
                guard let terminal = terminals.removeValue(forKey: id) else { continue }
                terminal.holder.stop()
                dispose(terminal)
            }
        }
    }

    func refresh(_ owner: String) async {
        await refresh(ids: panels[owner]?.terminalIDs ?? [])
    }

    func confirmClosing(owners: [String], proceed: @escaping @MainActor () -> Void) {
        var ids: [String] = []
        for owner in owners { ids += panels[owner]?.terminalIDs ?? [] }
        let finish: @MainActor () -> Void = { [weak self] in
            self?.closeAll(owners: owners)
            proceed()
        }
        guard !ids.isEmpty, HerdrTerminalSettings.load(defaults).confirmClose else {
            finish()
            return
        }
        let key = Set(owners)
        guard confirming.isDisjoint(with: key) else { return }
        confirming.formUnion(key)
        Task {
            await refresh(ids: ids)
            confirming.subtract(key)
            var running: [String] = []
            for id in ids {
                guard let terminal = terminals[id], terminal.running else { continue }
                running.append(terminal.title)
            }
            if running.isEmpty {
                finish()
            } else {
                closeRequest = HerdrTerminalCloseRequest(running: running, proceed: finish)
            }
        }
    }

    func retarget(previous: [HerdrTab], current: [HerdrTab], fallback: String) {
        let moves = HerdrTerminalOwnership.moves(
            owners: Array(panels.keys), previous: previous, current: current, fallback: fallback)
        for move in moves { adopt(move.owner, into: move.destination) }
    }

    private func adopt(_ owner: String, into destination: String) {
        guard let moved = panels.removeValue(forKey: owner) else { return }
        var target = panels[destination] ?? HerdrTerminalPanel()
        target.terminalIDs += moved.terminalIDs
        target.selectedID = target.selectedID ?? moved.selectedID
        target.open = target.open || moved.open
        panels[destination] = target
        if focusedOwner == owner { focusedOwner = destination }
    }

    private func refresh(ids: [String]) async {
        for id in ids {
            guard let terminal = terminals[id], let pane = terminal.pane else { continue }
            guard
                let state = try? await operations.state(
                    terminal.session, pane, terminal.host.machine),
                terminals[id]?.pane == pane
            else { continue }
            switch state {
            case .missing:
                remove(id)?.holder.stop()
            case .live(let process):
                if terminals[id]?.process != process { terminals[id]?.process = process }
            }
        }
    }

    private func dispose(_ terminal: HerdrPanelTerminal) {
        guard let pane = terminal.pane else { return }
        let operations = operations
        let session = terminal.session
        let machine = terminal.host.machine
        Task { try? await operations.close(session, pane, machine) }
    }

    @discardableResult
    private func remove(_ id: String) -> HerdrPanelTerminal? {
        guard let terminal = terminals.removeValue(forKey: id) else { return nil }
        for (owner, panel) in panels {
            guard let index = panel.terminalIDs.firstIndex(of: id) else { continue }
            var updated = panel
            updated.terminalIDs.remove(at: index)
            if updated.terminalIDs.isEmpty {
                panels.removeValue(forKey: owner)
                if focusedOwner == owner { focusedOwner = nil }
            } else {
                if updated.selectedID == id {
                    updated.selectedID = updated.terminalIDs[max(0, index - 1)]
                }
                panels[owner] = updated
            }
            break
        }
        return terminal
    }
}
