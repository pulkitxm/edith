import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

public struct RemoteRunner {
    public let machine: Machine
    private let connection: SSHConnection
    private let owner: MachineExecutionOwner
    private let makeProcess: @Sendable (String) -> Process
    private let connectAction: (@Sendable () async throws -> Void)?
    private let disconnectAction: (@Sendable () async -> Void)?
    private let runAction: (@Sendable (String, Data?, TimeInterval) async throws -> SSHExecResult)?

    public init(
        machine: Machine, connection: SSHConnection? = nil,
        owner: MachineExecutionOwner = MachineExecutionOwner(),
        makeProcess: (@Sendable (String) -> Process)? = nil,
        connect: (@Sendable () async throws -> Void)? = nil,
        disconnect: (@Sendable () async -> Void)? = nil,
        run: (@Sendable (String, Data?, TimeInterval) async throws -> SSHExecResult)? = nil
    ) {
        self.machine = machine
        let connection = connection ?? SSHConnection(machine: machine, controlSocketMode: .shared)
        self.connection = connection
        self.owner = owner
        self.makeProcess = makeProcess ?? { connection.streamProcess(command: $0) }
        connectAction = connect
        disconnectAction = disconnect
        runAction = run
    }

    public var ssh: SSHConnection { connection }

    public func connect() async throws {
        do {
            if let connectAction {
                try await connectAction()
            } else {
                try await connection.connect()
            }
        } catch {
            throw CLIFailure.unavailable(
                "could not reach \(machine.name): \(error.localizedDescription)",
                hint: "check the machine is awake and reachable, then retry")
        }
    }

    public func disconnect() async {
        if let disconnectAction { await disconnectAction(); return }
        await connection.disconnect()
    }

    @discardableResult
    public func run(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 60) async throws
        -> SSHExecResult
    {
        do {
            if let runAction { return try await runAction(command, stdin, timeout) }
            return try await connection.run(command, stdin: stdin, timeout: timeout)
        } catch {
            throw CLIFailure.unavailable(
                "\(machine.name): \(error.localizedDescription)")
        }
    }

    public func text(_ command: String, timeout: TimeInterval = 60) async throws -> String {
        let result = try await run(command, timeout: timeout)
        guard result.succeeded else {
            let detail = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            throw CLIFailure(
                "\(command) exited \(result.status) on \(machine.name)",
                hint: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdoutText
    }

    public func interactive(_ command: String?) throws -> Int32 {
        try MachinesCLIEnvironment.interactive(
            machine, connection.terminalArguments(remoteCommand: command),
            connection.terminalEnvironment())
    }

    public func passthrough(_ command: String) async -> Int32 {
        let process = makeProcess(command)
        let outputSink = ExtensionCLIContext.outputSink
        let stream = SSHLineStream(
            process: process, stdinData: ExtensionCLIContext.request?.standardInput,
            onLine: { _, _ in }, onExit: { _ in },
            onData: { data, isStderr in
                ExtensionCLIContext.$outputSink.withValue(outputSink) {
                    let text = String(decoding: data, as: UTF8.self)
                    if isStderr { CLIOut.rawError(text) } else { CLIOut.raw(text) }
                }
            })
        do {
            try owner.start(stream)
        } catch {
            CLIOut.note("error: could not start ssh: \(error.localizedDescription)")
            return 1
        }
        defer { owner.release(stream) }
        let code = await stream.waitForExit()
        await stream.waitForProcessExit()
        return code
    }

    public func finish(_ stream: SSHLineStream) async {
        stream.cancel()
        await stream.waitForProcessExit()
        owner.release(stream)
    }

    public func stream(
        command: String, stdin: Data? = nil, onLine: @escaping @Sendable (String, Bool) -> Void
    ) throws -> SSHLineStream {
        let process = makeProcess(command)
        let outputSink = ExtensionCLIContext.outputSink
        let stream = SSHLineStream(
            process: process, stdinData: stdin,
            onLine: { line, error in
                ExtensionCLIContext.$outputSink.withValue(outputSink) { onLine(line, error) }
            }, onExit: { _ in })
        try owner.start(stream)
        return stream
    }
}
