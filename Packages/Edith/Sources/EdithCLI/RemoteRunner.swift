import EdithKit
import Foundation

public struct RemoteRunner {
    public let machine: Machine
    private let connection: SSHConnection

    public init(machine: Machine) {
        self.machine = machine
        connection = SSHConnection(machine: machine)
    }

    public var ssh: SSHConnection { connection }

    public func connect() async throws {
        do {
            try await connection.connect()
        } catch {
            throw CLIFailure.unavailable(
                "could not reach \(machine.name): \(error.localizedDescription)",
                hint: "check the machine is awake and reachable, then retry")
        }
    }

    public func disconnect() async {
        await connection.disconnect()
    }

    @discardableResult
    public func run(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 60) async throws
        -> SSHExecResult
    {
        do {
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

    public func interactive(_ command: String?) -> Int32 {
        let process = Process()
        process.executableURL = SSHConnection.executable
        process.arguments = connection.terminalArguments(remoteCommand: command)
        process.environment = connection.terminalEnvironment().reduce(into: [String: String]()) {
            partial, entry in
            guard let index = entry.firstIndex(of: "=") else { return }
            partial[String(entry[entry.startIndex..<index])] =
                String(entry[entry.index(after: index)...])
        }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        guard (try? process.run()) != nil else {
            CLIOut.note("error: could not start ssh")
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func passthrough(_ command: String) async -> Int32 {
        let process = connection.streamProcess(command: command)
        process.standardInput = FileHandle.standardInput
        let stream = SSHLineStream(
            process: process,
            onLine: { line, isStderr in
                if isStderr {
                    CLIOut.rawError(line + "\n")
                } else {
                    CLIOut.raw(line + "\n")
                }
            },
            onExit: { _ in })
        do {
            try stream.start()
        } catch {
            CLIOut.note("error: could not start ssh: \(error.localizedDescription)")
            return 1
        }
        return await stream.waitForExit()
    }

    public func stream(
        command: String, stdin: Data? = nil, onLine: @escaping @Sendable (String, Bool) -> Void
    ) throws -> SSHLineStream {
        let process = connection.streamProcess(command: command)
        let stream = SSHLineStream(
            process: process, stdinData: stdin, onLine: onLine, onExit: { _ in })
        try stream.start()
        return stream
    }
}
