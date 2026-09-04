import EdithKit
import Foundation

public enum AgentMachineOperations {
    public typealias Command =
        @Sendable (AgentMachineCommandRequest, AgentTaskContext) async throws -> SSHExecResult
    public typealias Transfer =
        @Sendable (AgentMachineTransferRequest, @escaping @Sendable (Int64) -> Void) async throws ->
        Int64

    public static func register(
        on tasks: AgentTaskService, command: Command? = nil, transfer: Transfer? = nil
    ) async {
        let command = command ?? executeCommand
        let transfer = transfer ?? executeTransfer
        await tasks.register(operation: AgentMachineTaskOperation.command) { payload, context in
            let request = try AgentPayload.decode(AgentMachineCommandRequest.self, from: payload)
            guard request.timeout.isFinite, request.timeout > 0,
                !request.command.contains("\0")
            else { throw AgentError(.refused, "The machine command request is invalid.") }
            try Task.checkCancellation()
            return try AgentPayload.encode(await command(request, context))
        }
        await tasks.register(operation: AgentMachineTaskOperation.transfer) { payload, context in
            let request = try AgentPayload.decode(AgentMachineTransferRequest.self, from: payload)
            guard request.localURL.isFileURL, request.localURL.path.hasPrefix("/"),
                !request.remotePath.isEmpty, !request.remotePath.contains("\0"),
                request.timeout.isFinite, request.timeout > 0
            else { throw AgentError(.refused, "The file transfer request is invalid.") }
            let progress = AgentMachineTransferProgress { context.report("bytes:\($0)") }
            let bytes = try await withThrowingTaskGroup(of: Int64.self) { group in
                group.addTask {
                    try await transfer(request) { progress.report($0) }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(min(request.timeout, 7_200)))
                    throw CLICommandRunnerError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? 0
            }
            try Task.checkCancellation()
            return try AgentPayload.encode(AgentMachineTransferResult(bytes: bytes))
        }
    }

    private static func executeCommand(
        _ request: AgentMachineCommandRequest, context: AgentTaskContext
    ) async throws -> SSHExecResult {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        if let machine = request.machine {
            let connection = try await AgentMachineConnectionPool.shared.connection(for: machine)
            executable = SSHConnection.executable
            arguments = connection.execArguments(command: request.command)
            environment = MachineSSHEnvironment.make(for: machine)
        } else {
            executable = URL(fileURLWithPath: "/bin/zsh")
            arguments = ["-lc", request.command]
            environment = CLIToolEnvironment.sanitized()
        }
        try Task.checkCancellation()
        let result = try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: executable, arguments: arguments, environment: environment,
                timeout: min(request.timeout, 7_200), maximumOutputBytes: 2 << 20,
                standardInputData: request.standardInput, terminatesProcessGroup: true),
            streamsWhileRunning: true,
            onStandardOutputLine: { context.report($0, stream: .standardOutput) },
            onStandardErrorLine: { context.report($0, stream: .standardError) })
        return SSHExecResult(
            status: result.terminationStatus, stdout: result.standardOutputData,
            stderr: result.standardErrorData)
    }

    private static func executeTransfer(
        _ request: AgentMachineTransferRequest, progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let connection = try await AgentMachineConnectionPool.shared.connection(
            for: request.machine)
        try Task.checkCancellation()
        switch request.direction {
        case .upload:
            try await connection.upload(
                localURL: request.localURL, toRemotePath: request.remotePath, progress: progress)
        case .download:
            try await AgentMachineDownload.write(to: request.localURL) { staged in
                try await connection.download(
                    remotePath: request.remotePath, to: staged, progress: progress)
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: request.localURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

enum AgentMachineDownload {
    static func write(
        to destination: URL, receive: @Sendable (URL) async throws -> Void
    ) async throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".edith-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await receive(staged)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
}

actor AgentMachineConnectionPool {
    typealias Prepare = @Sendable (SSHConnection) async throws -> Void

    static let shared = AgentMachineConnectionPool()
    private let maximumConnections: Int
    private let prepare: Prepare
    private var connections: [Machine: SSHConnection] = [:]
    private var preparing: [Machine: Task<SSHConnection, Error>] = [:]
    private var order: [Machine] = []

    init(
        maximumConnections: Int = 32,
        prepare: @escaping Prepare = { try await $0.connect() }
    ) {
        self.maximumConnections = max(1, maximumConnections)
        self.prepare = prepare
    }

    func connection(for machine: Machine) async throws -> SSHConnection {
        if let pending = preparing[machine] { return try await pending.value }
        let connection =
            connections[machine]
            ?? SSHConnection(machine: machine, controlSocketMode: .shared)
        let pending = Task { [prepare] in
            try await prepare(connection)
            return connection
        }
        preparing[machine] = pending
        do {
            let value = try await pending.value
            preparing[machine] = nil
            connections[machine] = value
            order.removeAll { $0 == machine }
            order.append(machine)
            while order.count > maximumConnections {
                connections[order.removeFirst()] = nil
            }
            return value
        } catch {
            preparing[machine] = nil
            connections[machine] = nil
            order.removeAll { $0 == machine }
            throw error
        }
    }
}

private final class AgentMachineTransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let publish: @Sendable (Int64) -> Void
    private var last = ContinuousClock.now
    private var reported = false

    init(publish: @escaping @Sendable (Int64) -> Void) { self.publish = publish }

    func report(_ bytes: Int64) {
        lock.withLock {
            let now = ContinuousClock.now
            guard !reported || now - last >= .milliseconds(250) else { return }
            reported = true
            last = now
            publish(bytes)
        }
    }
}
