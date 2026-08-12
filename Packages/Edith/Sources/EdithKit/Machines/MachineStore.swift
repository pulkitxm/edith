import Foundation
import Observation

@MainActor
@Observable
public final class MachineStore {
    public private(set) var machines: [Machine] = []
    public private(set) var forwards: [PortForward] = []
    public private(set) var snippets: [CommandSnippet] = []

    private let files: MachineRegistry.Files

    public init(
        machinesFile: URL = MachinePaths.machinesFile,
        forwardsFile: URL = MachinePaths.forwardsFile,
        snippetsFile: URL = MachinePaths.snippetsFile
    ) {
        files = MachineRegistry.Files(
            machines: machinesFile, forwards: forwardsFile, snippets: snippetsFile)
        reload()
    }

    public func reload() {
        let contents = MachineRegistry.load(files)
        machines = contents.machines
        forwards = contents.forwards
        snippets = contents.snippets
    }

    public func machine(id: UUID) -> Machine? {
        machines.first { $0.id == id }
    }

    public func add(_ machine: Machine) {
        machines = MachineRegistry.add(machine, files)
    }

    public func update(_ machine: Machine) {
        machines = MachineRegistry.update(machine, files)
    }

    public func remove(id: UUID) {
        let contents = MachineRegistry.remove(id: id, files)
        machines = contents.machines
        forwards = contents.forwards
        snippets = contents.snippets
    }

    public func addForward(_ forward: PortForward) {
        forwards = MachineRegistry.addForward(forward, files)
    }

    public func removeForward(id: UUID) {
        forwards = MachineRegistry.removeForward(id: id, files)
    }

    public func forwards(machineID: UUID) -> [PortForward] {
        MachineRegistry.forwards(machineID: machineID, in: forwards)
    }

    public func addSnippet(_ snippet: CommandSnippet) {
        snippets = MachineRegistry.addSnippet(snippet, files)
    }

    public func updateSnippet(_ snippet: CommandSnippet) {
        snippets = MachineRegistry.updateSnippet(snippet, files)
    }

    public func removeSnippet(id: UUID) {
        snippets = MachineRegistry.removeSnippet(id: id, files)
    }

    public func snippets(machineID: UUID) -> [CommandSnippet] {
        MachineRegistry.snippets(machineID: machineID, in: snippets)
    }
}
