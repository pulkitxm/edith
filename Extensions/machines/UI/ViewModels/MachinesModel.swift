import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor
@Observable
final class MachinesModel {
    static var shared = MachinesModel()

    private(set) var store: MachineStore
    let uiClient: MachineUIClient?
    var operationError: String?
    private(set) var sessions: [UUID: MachineSession] = [:]
    private(set) var sshClipboardStates: [UUID: SSHClipboardSyncState] = [:]
    var selection: UUID?

    static let localMachineID = Machine.localID

    let localMachine = Machine.local

    private var machinesObserver: NSObjectProtocol?
    private var mutationJob: Task<Void, Never>?
    private var mutationSequence = 0

    init(uiClient: MachineUIClient? = nil) {
        self.uiClient = uiClient
        store = MachineStore(inMemory: uiClient != nil)
        guard uiClient == nil else { return }
        machinesObserver = IPC.observe("machinesChanged") { [weak self] in
            Task { @MainActor in
                self?.store.reload()
                self?.ensureSelection()
            }
        }
    }

    func applyUIState(_ state: MachineUIState) {
        guard uiClient != nil else { return }
        sshClipboardStates = state.clipboardStates
        store.apply(
            .init(machines: state.machines, forwards: state.forwards, snippets: state.snippets))
        let known = Set(allMachines.map(\.id))
        sessions = sessions.filter { known.contains($0.key) }
        for value in state.sessions where known.contains(value.machine.id) {
            if sessions[value.machine.id]?.machine != value.machine {
                sessions[value.machine.id] = nil
            }
            session(for: value.machine.id).applyUIState(value)
        }
        ensureSelection()
        operationError = nil
    }

    func reloadOwnedRecords() { store.reload(); ensureSelection() }

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
        let session = MachineSession(
            machine: machine ?? Machine.missing(id: id), local: isLocal,
            synthetic: ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil,
            uiClient: uiClient)
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

    func add(_ machine: Machine, secrets: MachineSecretChanges = MachineSecretChanges()) {
        enqueueMutation(.add, machine: machine, secrets: secrets) { [weak self] _ in
            guard let self else { return }
            self.store.reload()
            self.selection = machine.id
            let session = self.session(for: machine.id)
            session.start()
            await self.reconcileSSHClipboardNow(machine, connection: session.connectionRef)
        }
    }

    func update(_ machine: Machine, secrets: MachineSecretChanges = MachineSecretChanges()) {
        enqueueMutation(.edit, machine: machine, secrets: secrets) { [weak self] previous in
            guard let self else { return }
            self.store.reload()
            if let session = self.sessions[machine.id] {
                session.stop()
                self.sessions[machine.id] = nil
            }
            let session = self.session(for: machine.id)
            await self.reconcileSSHClipboardNow(
                machine, replacing: previous,
                connection: machine.sshClipboardEnabled ? session.connectionRef : nil)
        }
    }

    func remove(id: UUID) {
        guard let machine = store.machine(id: id) else { return }
        enqueueMutation(.remove, machine: machine) { [weak self] previous in
            guard let self else { return }
            self.sessions[id]?.stop()
            self.sessions[id] = nil
            self.store.reload()
            let disabled = MachineMutationReconciliation.removalTarget(
                submitted: machine, effectivePrevious: previous)
            await self.reconcileSSHClipboardNow(
                disabled, replacing: previous ?? machine)
            self.ensureSelection()
        }
    }

    private func enqueueMutation(
        _ operation: MachineMutationOperation, machine: Machine,
        secrets: MachineSecretChanges = MachineSecretChanges(),
        completion: @escaping @MainActor (Machine?) async -> Void
    ) {
        if let uiClient {
            uiClient.enqueue {
                try await uiClient.mutate(
                    MachineUIMutation(operation: operation, machine: machine, secrets: secrets))
            }
            return
        }
        let predecessor = mutationJob
        mutationSequence += 1
        let sequence = mutationSequence
        mutationJob = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            let previous = await Task.detached(priority: .utility) {
                let previous = MachineMutationReconciliation.previous(
                    for: operation, machineID: machine.id,
                    machines: MachineRegistry.machines())
                MachineMutationOperationExecution.perform(
                    operation, machine: machine, secrets: secrets,
                    notify: { IPC.post("machinesChanged") })
                return previous
            }.value
            guard !Task.isCancelled, let self else { return }
            await completion(previous)
            if self.mutationSequence == sequence {
                self.mutationJob = nil
            }
        }
    }

    func performConnection(_ operation: MachineConnectionOperation, for session: MachineSession) {
        Task {
            _ = await MachineConnectionOperationExecution.perform(
                operation,
                connect: {
                    session.start()
                    return nil
                },
                disconnect: { session.stop() })
        }
    }

    func startSelected() {
        guard let selection else { return }
        let session = session(for: selection)
        if case .disconnected = session.state {
            session.start()
        }
    }

    func shutdown() async {
        mutationJob?.cancel()
        IPC.stopObserving(machinesObserver)
        machinesObserver = nil
        let retained = Array(sessions.values)
        stopAll()
        for session in retained { await session.shutdown() }
        await mutationJob?.value
        mutationJob = nil
    }

    func stopAll() {
        for session in sessions.values { session.stop() }
        sessions = [:]
    }

    func performForward(
        _ operation: MachineForwardOperation, forward: PortForward
    ) async -> Result<MachineForwardOperationResult, Error> {
        if let uiClient {
            if operation == .enable || operation == .disable {
                if let error = await session(for: forward.machineID).setForward(
                    forward, active: operation == .enable)
                {
                    return .failure(MachineForwardOperationError.liveActionFailed(error))
                }
                return .success(
                    .init(operation: operation, forward: forward, active: operation == .enable))
            }
            var value = MachineUIAction(
                operation: operation == .add ? .forwardAdd : .forwardRemove,
                machineID: forward.machineID)
            value.forward = forward
            do { return .success(try await uiClient.action(value)) } catch {
                return .failure(error)
            }
        }
        let session = session(for: forward.machineID)
        let needsLiveAction =
            operation == .enable || operation == .disable
            || (operation == .remove && session.activeForwards.contains(forward.id))
        let setActive: MachineForwardOperationExecution.SetActive? =
            needsLiveAction
            ? { candidate, active in await session.setForward(candidate, active: active) }
            : nil
        return await MachineForwardOperationExecution.perform(
            operation, forward: forward, existing: store.forwards,
            persistAdd: { self.store.addForward($0) },
            persistRemove: { self.store.removeForward(id: $0) }, setActive: setActive,
            notify: { IPC.post("machinesChanged") })
    }

    func performSnippet(
        _ operation: MachineSnippetOperation, snippet: CommandSnippet
    ) async -> Result<MachineSnippetOperationResult, Error> {
        if let uiClient {
            var value = MachineUIAction(
                operation: operation == .add ? .snippetAdd : .snippetRemove,
                machineID: snippet.machineID ?? selection ?? Machine.localID)
            value.snippet = snippet
            do { return .success(try await uiClient.action(value)) } catch {
                return .failure(error)
            }
        }
        return MachineSnippetOperationExecution.perform(
            operation, snippet: snippet,
            persistAdd: { store.addSnippet($0) },
            persistRemove: { store.removeSnippet(id: $0) },
            notify: { IPC.post("machinesChanged") })
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
        guard uiClient == nil else { return }
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
        Task {
            await reconcileSSHClipboardNow(
                machine, replacing: previous, connection: connection)
        }
    }

    private func reconcileSSHClipboardNow(
        _ machine: Machine, replacing previous: Machine? = nil,
        connection: SSHConnection? = nil
    ) async {
        sshClipboardStates[machine.id] = machine.sshClipboardEnabled ? .configuring : .disabled
        do {
            try await SSHClipboardManager.shared.reconcile(
                machine, replacing: previous, connection: connection)
            sshClipboardStates[machine.id] = machine.sshClipboardEnabled ? .active : .disabled
        } catch {
            sshClipboardStates[machine.id] = .failed(error.localizedDescription)
        }
    }

}

enum MachineMutationReconciliation {
    static func previous(
        for operation: MachineMutationOperation, machineID: UUID, machines: [Machine]
    ) -> Machine? {
        switch operation {
        case .add:
            return nil
        case .edit, .remove:
            return machines.first { $0.id == machineID }
        }
    }

    static func removalTarget(
        submitted: Machine, effectivePrevious: Machine?
    ) -> Machine {
        var target = effectivePrevious ?? submitted
        target.sshClipboardEnabled = false
        return target
    }
}

enum MachineTab: String, CaseIterable, Identifiable {
    case overview
    case processes
    case docker
    case terminal
    case files
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .processes: return "Processes"
        case .docker: return "Docker"
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.needle"
        case .processes: return "list.bullet.rectangle"
        case .docker: return "shippingbox"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    static func tabs(isLocal: Bool, hasDocker: Bool) -> [MachineTab] {
        if isLocal { return [.overview, .processes, .terminal, .files] }
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
