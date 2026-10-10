import EdithExtensionSupport
import Foundation

@MainActor final class MachineCLIService {
    private let owner = MachineExecutionOwner()
    private var connections: [UUID: SSHConnection] = [:]
    private var stopped = false

    func runner(_ machine: Machine) -> RemoteRunner {
        let connection: SSHConnection
        if let retained = connections[machine.id] {
            connection = retained
        } else {
            connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
            connections[machine.id] = connection
        }
        return RemoteRunner(machine: machine, connection: connection, owner: owner)
    }

    func execute(_ input: MachineCLIInput) async throws -> ExtensionCLIReply {
        try input.validate()
        return try await MachineCLIContext.$input.withValue(input.standardInput) {
            try await MachineWorkingDirectory.$terminalSession.withValue(input.terminalSession) {
                try await executeRequest(ExtensionCLIRequest(arguments: input.arguments))
            }
        }
    }

    private func executeRequest(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let previous = MachinesCLIEnvironment.runner
        MachinesCLIEnvironment.runner = { self.runner($0) }
        defer { MachinesCLIEnvironment.runner = previous }
        let result = try await MachinesCLIExecution.run(request)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return result
    }

    func shutdown() async {
        stopped = true
        await owner.shutdown()
        let retained = Array(connections.values)
        connections = [:]
        for connection in retained { await connection.disconnect() }
    }
}
