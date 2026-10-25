import Foundation

extension RemoteTransferEndpoint {
    public static func remote(
        machine: Machine, connection: SSHConnection,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) -> RemoteTransferEndpoint {
        remote(
            machineID: machine.id, name: machine.name, connection: connection, progress: progress)
    }
}

extension RemoteDirectoryEndpoint {
    public static func remote(machine: Machine, connection: SSHConnection) -> Self {
        remote(machineName: machine.name, connection: connection)
    }

    public static func local(machine: Machine) -> Self {
        local(machineName: machine.name)
    }
}
