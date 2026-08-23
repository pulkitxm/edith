import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MachinesModel {
    static let shared = MachinesModel()

    private(set) var store = MachineStore()
    private(set) var sessions: [UUID: MachineSession] = [:]
    private(set) var sshClipboardStates: [UUID: SSHClipboardSyncState] = [:]
    var selection: UUID?

    static let localMachineID = Machine.localID

    let localMachine = Machine.local

    private var machinesObserver: NSObjectProtocol?

    private init() {
        machinesObserver = IPC.observe(IPC.Name.machinesChanged) { [weak self] in
            Task { @MainActor in
                self?.store.reload()
                self?.ensureSelection()
            }
        }
    }

    var allMachines: [Machine] {
        [localMachine] + store.machines
    }

    func isLocal(_ id: UUID) -> Bool { id == Self.localMachineID }

    func knows(_ id: UUID) -> Bool {
        id == Self.localMachineID || store.machine(id: id) != nil
    }

    func session(for id: UUID) -> MachineSession {
        if let existing = sessions[id] { return existing }
        let isLocal = id == Self.localMachineID
        let machine = isLocal ? localMachine : store.machine(id: id)
        let session = MachineSession(machine: machine ?? Machine.missing(id: id), local: isLocal)
        sessions[id] = session
        return session
    }

    func selectedSession() -> MachineSession? {
        guard let selection else { return nil }
        return session(for: selection)
    }

    func ensureSelection() {
        if let selection, allMachines.contains(where: { $0.id == selection }) { return }
        selection = allMachines.first?.id
    }

    func restoreSelection(_ stored: String) {
        if selection == nil, let id = UUID(uuidString: stored),
            allMachines.contains(where: { $0.id == id })
        {
            selection = id
        }
        ensureSelection()
    }

    func add(_ machine: Machine) {
        store.add(machine)
        selection = machine.id
        let session = session(for: machine.id)
        session.start()
        reconcileSSHClipboard(machine, connection: session.connectionRef)
    }

    func update(_ machine: Machine) {
        let previous = store.machine(id: machine.id)
        store.update(machine)
        if let session = sessions[machine.id] {
            session.stop()
            sessions[machine.id] = nil
        }
        let session = session(for: machine.id)
        reconcileSSHClipboard(
            machine, replacing: previous,
            connection: machine.sshClipboardEnabled ? session.connectionRef : nil)
    }

    func remove(id: UUID) {
        let machine = store.machine(id: id)
        sessions[id]?.stop()
        sessions[id] = nil
        store.remove(id: id)
        if var machine {
            machine.sshClipboardEnabled = false
            reconcileSSHClipboard(machine, replacing: machine)
        }
        ensureSelection()
    }

    func startSelected() {
        guard let selection else { return }
        let session = session(for: selection)
        if case .disconnected = session.state {
            session.start()
        }
    }

    func stopAll() {
        for session in sessions.values { session.stop() }
        sessions = [:]
    }

    func addForward(_ forward: PortForward) {
        store.addForward(forward)
    }

    func removeForward(_ forward: PortForward) {
        Task { await session(for: forward.machineID).setForward(forward, active: false) }
        store.removeForward(id: forward.id)
    }

    func addSnippet(_ snippet: CommandSnippet) {
        store.addSnippet(snippet)
    }

    func removeSnippet(_ snippet: CommandSnippet) {
        store.removeSnippet(id: snippet.id)
    }

    func snapshot(for id: UUID) -> MachineSnapshot {
        let session = session(for: id)
        let machine = session.machine
        let sample = session.sample
        let slow = session.slow
        let disks: [MachineFilesystem] = (slow?.disks ?? []).filter { $0.totalKB > 0 }
        return MachineSnapshot(
            id: id, name: machine.name, isLocal: isLocal(id),
            online: session.state.isConnected,
            cores: session.hello?.cores ?? sample?.cpu.cores.count ?? 0,
            cpuPercent: sample?.cpu.total ?? 0,
            memoryTotalKB: sample?.mem.totalKB ?? 0,
            memoryUsedKB: sample?.mem.usedKB ?? 0,
            swapTotalKB: sample?.mem.swapTotalKB ?? 0,
            swapUsedKB: sample?.mem.swapUsedKB ?? 0,
            diskTotalKB: disks.reduce(0) { $0 + $1.totalKB },
            diskUsedKB: disks.reduce(0) { $0 + $1.usedKB },
            loadOne: sample?.load.first ?? 0,
            uptime: sample?.uptime ?? 0,
            containersRunning: session.containers.filter { $0.state.isRunning }.count,
            containersTotal: session.containers.count,
            updatesAvailable: session.facts.updatesAvailable,
            hottestTemperature: slow?.temps.map(\.c).max(),
            os: session.hello?.os ?? "")
    }

    var snapshots: [MachineSnapshot] {
        allMachines.map { snapshot(for: $0.id) }
    }

    var fleet: FleetSummary {
        FleetMath.summarize(snapshots)
    }

    func connectAll() {
        for machine in allMachines {
            let session = session(for: machine.id)
            if case .disconnected = session.state { session.start() }
        }
    }

    func reconcileSSHClipboards() {
        for machine in store.machines where machine.sshClipboardEnabled {
            if sshClipboardStates[machine.id] == .active
                || sshClipboardStates[machine.id] == .configuring
            {
                continue
            }
            reconcileSSHClipboard(machine, connection: session(for: machine.id).connectionRef)
        }
    }

    func sshClipboardState(for machine: Machine) -> SSHClipboardSyncState {
        sshClipboardStates[machine.id] ?? (machine.sshClipboardEnabled ? .configuring : .disabled)
    }

    private func reconcileSSHClipboard(
        _ machine: Machine, replacing previous: Machine? = nil,
        connection: SSHConnection? = nil
    ) {
        sshClipboardStates[machine.id] = machine.sshClipboardEnabled ? .configuring : .disabled
        Task {
            do {
                try await SSHClipboardManager.shared.reconcile(
                    machine, replacing: previous, connection: connection)
                sshClipboardStates[machine.id] = machine.sshClipboardEnabled ? .active : .disabled
            } catch {
                sshClipboardStates[machine.id] = .failed(error.localizedDescription)
            }
        }
    }

    func wake(machine: Machine) -> String {
        guard let mac = machine.wakeMACAddress,
            let packet = WakeOnLAN.magicPacket(macAddress: mac)
        else {
            return "No MAC address stored for this machine yet."
        }
        return MagicPacket.send(packet) ?? "Sent a wake packet to \(mac)."
    }
}

enum SSHClipboardSyncState: Equatable {
    case disabled
    case configuring
    case active
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "Clipboard sync disabled"
        case .configuring: return "Setting up clipboard sync"
        case .active: return "Clipboard sync active"
        case let .failed(message): return "Clipboard sync failed: \(message)"
        }
    }

    var symbol: String {
        switch self {
        case .disabled: return "clipboard"
        case .configuring: return "arrow.triangle.2.circlepath"
        case .active: return "clipboard.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

enum MachineTab: String, CaseIterable, Identifiable {
    case overview
    case processes
    case docker
    case terminal
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .processes: return "Processes"
        case .docker: return "Docker"
        case .terminal: return "Terminal"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.needle"
        case .processes: return "list.bullet.rectangle"
        case .docker: return "shippingbox"
        case .terminal: return "terminal"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    static func tabs(isLocal: Bool, hasDocker: Bool) -> [MachineTab] {
        if isLocal { return [.overview, .processes, .terminal] }
        return MachineTab.allCases.filter { $0 != .docker || hasDocker }
    }
}

enum MachineStatusStyle {
    static func color(_ state: MachineConnectionState, dark: Bool) -> Color {
        switch state {
        case .connected(let latency):
            guard let latency else { return DashSkin.ok }
            if latency > 400 { return DashSkin.warn }
            return DashSkin.ok
        case .connecting, .reconnecting: return DashSkin.gold
        case .disconnected: return DashSkin.inkFaint(dark)
        case .failed: return DashSkin.danger
        }
    }

    static func label(_ state: MachineConnectionState) -> String {
        switch state {
        case let .connected(latency):
            guard let latency else { return "Connected" }
            return String(format: "%.0f ms", latency)
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Not connected"
        case .failed: return "Connection failed"
        }
    }

    static func detail(_ state: MachineConnectionState) -> String {
        state.failureMessage ?? label(state)
    }
}
