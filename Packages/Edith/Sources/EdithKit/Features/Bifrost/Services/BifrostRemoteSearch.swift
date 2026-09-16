import Foundation

public enum BifrostRemoteSearch {
    public static func machines(
        registry: [Machine] = MachineRegistry.machines()
    ) -> [Machine] {
        registry.filter { $0.id != Machine.localID }
    }

    public static func machine(named name: String, in registry: [Machine]) -> Machine? {
        registry.first { $0.name == name }
    }

    public static func run(
        machineName: String, command: String, registry: [Machine] = MachineRegistry.machines()
    ) async -> String? {
        guard let machine = machine(named: machineName, in: machines(registry: registry)) else {
            return nil
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        let result: SSHExecResult? = try? await connection.runChecked(command, timeout: 15)
        await connection.disconnect()
        return result?.stdoutText
    }
}
