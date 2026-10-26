import Foundation

@MainActor
final class MachineEngineModels {
    let machines: MachinesModel
    let workspace: WorkspaceModel

    init() {
        machines = MachinesModel()
        workspace = WorkspaceModel(machines: machines)
    }

    func state() -> MachineUIState {
        machines.reloadOwnedRecords()
        return MachineUIState(
            machines: machines.store.machines, forwards: machines.store.forwards,
            snippets: machines.store.snippets,
            sessions: machines.allMachines.map { machines.session(for: $0.id).uiState() },
            workspaces: WorkspaceStore.load(), clipboardStates: machines.sshClipboardStates)
    }

    func shutdown() async {
        await workspace.shutdown()
        await machines.shutdown()
    }
}
