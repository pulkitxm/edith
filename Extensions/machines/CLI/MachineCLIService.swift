import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor final class MachineCLIService {
    private let owner = MachineExecutionOwner()
    private let streams: ExtensionCLIStreams
    private let suppliedRunner: ((Machine, MachineExecutionOwner) -> RemoteRunner)?
    private let previousRunner: (Machine) -> RemoteRunner
    private var connections: [UUID: SSHConnection] = [:]
    private var stopped = false

    init(runner: ((Machine, MachineExecutionOwner) -> RemoteRunner)? = nil) throws {
        streams = try ExtensionCLIStreams(owner: "machines")
        suppliedRunner = runner
        previousRunner = MachinesCLIEnvironment.runner
        MachinesCLIEnvironment.runner = { self.runner($0) }
    }

    func runner(_ machine: Machine) -> RemoteRunner {
        if let suppliedRunner { return suppliedRunner(machine, owner) }
        let connection: SSHConnection
        if let retained = connections[machine.id] {
            connection = retained
        } else {
            connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
            connections[machine.id] = connection
        }
        return RemoteRunner(machine: machine, connection: connection, owner: owner)
    }

    func execute(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try request.validate()
        let result = try await MachinesCLIExecution.run(request)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return result
    }

    func invoke(_ operation: String, payload: Data) throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if operation == "machines.cli.stream.start" {
            let start = try JSONDecoder().decode(ExtensionCLIStreamStart.self, from: payload)
            try start.validate()
            let rewritten = ExtensionCLIStreamStart(
                owner: start.owner, session: start.session,
                request: try MachinesCLIExecution.rewrite(start.request), deadline: start.deadline)
            let handle = try MachineWorkingDirectory.$terminalSession.withValue(
                start.session.uuidString
            ) {
                try streams.start(MachinesCommand.self, request: rewritten)
            }
            return try JSONEncoder().encode(handle)
        }
        return try streams.invoke(
            MachinesCommand.self, operation: operation, prefix: "machines.cli.stream",
            payload: payload)
    }

    func shutdown() async {
        stopped = true
        streams.stop()
        owner.cancel()
        await streams.stopAndWait()
        await owner.shutdown()
        let retained = Array(connections.values)
        connections = [:]
        for connection in retained { await connection.disconnect() }
        MachinesCLIEnvironment.runner = previousRunner
    }
}
