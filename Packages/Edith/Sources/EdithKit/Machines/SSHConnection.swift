import Foundation

public struct SSHExecResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var combinedText: String { stdoutText + stderrText }
    public var succeeded: Bool { status == 0 }
}

public struct SSHOutputChunk: Sendable {
    public let isStderr: Bool
    public let text: String
}

public struct SSHConnectFailure: Equatable, Sendable {
    public let message: String
    public let isRecoverable: Bool

    public init(message: String, isRecoverable: Bool) {
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

public enum SSHConnectionError: LocalizedError {
    case connectFailed(SSHConnectFailure)
    case commandFailed(command: String, status: Int32, stderr: String)
    case transferFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .connectFailed(failure):
            return failure.message.isEmpty ? "Connection failed." : failure.message
        case let .commandFailed(command, status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) exited with status \(status)" : detail
        case let .transferFailed(message):
            return message
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var timeoutWorkItem: DispatchWorkItem?

    func install(_ workItem: DispatchWorkItem) {
        lock.lock()
        if claimed {
            lock.unlock()
            workItem.cancel()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        return true
    }
}

private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public actor SSHConnection {
    public let machine: Machine

    private var masterProcess: Process?
    private let socketPath: String
    private let knownHostsArgument: String

    public init(machine: Machine) {
        self.machine = machine
        socketPath = MachinePaths.socketFile(for: machine.id).path
        let userKnownHosts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts").path
        knownHostsArgument =
            "\"\(MachinePaths.knownHostsFile.path)\" \"\(userKnownHosts)\""
    }

    public nonisolated static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    public func connect() async throws {
        if await masterIsAlive() { return }
        MachinePaths.prepare()
        try? FileManager.default.removeItem(atPath: socketPath)
        masterProcess?.terminate()
        masterProcess = nil

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = masterArguments()
        process.environment = environment()
        let stderrPipe = Pipe()
        let buffer = PipeBuffer()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            PipeReading.consume(handle, receive: buffer.append)
        }
        do {
            try process.run()
        } catch {
            throw SSHConnectionError.connectFailed(
                SSHConnectFailure(message: error.localizedDescription, isRecoverable: true))
        }
        masterProcess = process

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(25))
        while clock.now < deadline {
            if process.isRunning, FileManager.default.fileExists(atPath: socketPath) { return }
            if !process.isRunning {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                masterProcess = nil
                throw SSHConnectionError.connectFailed(
                    Self.friendlyConnectError(String(decoding: buffer.snapshot(), as: UTF8.self)))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        masterProcess = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let pending = String(decoding: buffer.snapshot(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw SSHConnectionError.connectFailed(
            pending.isEmpty
                ? SSHConnectFailure(message: "Timed out while connecting.", isRecoverable: true)
                : Self.friendlyConnectError(pending))
    }

    public func disconnect() async {
        _ = try? await runControl(["-O", "exit"])
        masterProcess?.terminate()
        masterProcess = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    public func masterIsAlive() async -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let result = try? await runControl(["-O", "check"])
        return result?.status == 0
    }

    public func latencyMillis() async -> Double? {
        let start = DispatchTime.now()
        guard let result = try? await run("true", timeout: 10), result.succeeded else {
            return nil
        }
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    @discardableResult
    public func run(
        _ command: String, stdin: Data? = nil, timeout: TimeInterval = 60
    ) async throws -> SSHExecResult {
        let process = execProcess(command: command)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = {
            PipeReading.consume($0, receive: stdoutBuffer.append)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = {
            PipeReading.consume($0, receive: stderrBuffer.append)
        }
        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let status = await withTaskCancellationHandler {
            await Self.waitForExit(process, timeout: timeout)
        } onCancel: {
            process.terminate()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        return SSHExecResult(
            status: status, stdout: stdoutBuffer.snapshot(), stderr: stderrBuffer.snapshot())
    }

    @discardableResult
    public func runChecked(_ command: String, timeout: TimeInterval = 60) async throws
        -> SSHExecResult
    {
        let result = try await run(command, timeout: timeout)
        guard result.succeeded else {
            throw SSHConnectionError.commandFailed(
                command: command, status: result.status, stderr: result.stderrText)
        }
        return result
    }

    public nonisolated func streamProcess(command: String) -> Process {
        execProcess(command: command)
    }

    public func download(
        remotePath: String, to localURL: URL, progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let command = "cat \(ShellQuote.quote(remotePath))"
        let process = execProcess(command: command)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrBuffer = PipeBuffer()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        stderrPipe.fileHandleForReading.readabilityHandler = {
            PipeReading.consume($0, receive: stderrBuffer.append)
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: localURL) else {
            throw SSHConnectionError.transferFailed("Could not create the local file.")
        }
        try process.run()
        let reader = stdoutPipe.fileHandleForReading
        var written: Int64 = 0
        while true {
            let chunk = reader.readData(ofLength: 128 * 1024)
            if chunk.isEmpty { break }
            if Task.isCancelled {
                process.terminate()
                try? output.close()
                try? FileManager.default.removeItem(at: localURL)
                throw CancellationError()
            }
            output.write(chunk)
            written += Int64(chunk.count)
            progress?(written)
        }
        try? output.close()
        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: localURL)
            let message = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHConnectionError.transferFailed(
                message.isEmpty ? "Download failed." : message)
        }
    }

    public func upload(
        localURL: URL, toRemotePath remotePath: String,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        signal(SIGPIPE, SIG_IGN)
        guard let input = try? FileHandle(forReadingFrom: localURL) else {
            throw SSHConnectionError.transferFailed("Could not read the local file.")
        }
        let expected =
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64
            ?? -1
        let command = "cat > \(ShellQuote.quote(remotePath))"
        let process = execProcess(command: command)
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrBuffer = PipeBuffer()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = {
            PipeReading.consume($0, receive: stderrBuffer.append)
        }
        try process.run()
        let writer = stdinPipe.fileHandleForWriting
        var sent: Int64 = 0
        var writeFailure: Error?
        while true {
            let chunk = input.readData(ofLength: 128 * 1024)
            if chunk.isEmpty { break }
            if Task.isCancelled {
                process.terminate()
                try? input.close()
                try? writer.close()
                await discard(remotePath)
                throw CancellationError()
            }
            do {
                try writer.write(contentsOf: chunk)
            } catch {
                writeFailure = error
                break
            }
            sent += Int64(chunk.count)
            progress?(sent)
        }
        try? writer.close()
        try? input.close()
        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let reported = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard writeFailure == nil else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                reported.isEmpty
                    ? "The machine stopped accepting the file after \(sent) bytes."
                    : reported)
        }
        guard process.terminationStatus == 0 else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(reported.isEmpty ? "Upload failed." : reported)
        }
        guard expected < 0 || sent == expected else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                "Only \(sent) of \(expected) bytes were sent.")
        }
        guard let landed = await remoteSize(remotePath), landed == sent else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                "The machine kept a different file than the one that was sent.")
        }
    }

    public func remoteFileSize(_ path: String) async -> Int64? {
        await remoteSize(path)
    }

    private func remoteSize(_ path: String) async -> Int64? {
        let quoted = ShellQuote.quote(path)
        let command = "stat -c%s \(quoted) 2>/dev/null || stat -f%z \(quoted) 2>/dev/null"
        guard let result = try? await run(command, timeout: 30), result.succeeded else {
            return nil
        }
        return Int64(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func discard(_ path: String) async {
        _ = try? await run("rm -f \(ShellQuote.quote(path))", timeout: 30)
    }

    public func addForward(_ forward: PortForward) async throws {
        let result = try await runControl(["-O", "forward", "-L", forward.forwardSpec])
        guard result.status == 0 else {
            throw SSHConnectionError.commandFailed(
                command: "forward", status: result.status, stderr: result.stderrText)
        }
    }

    public func cancelForward(_ forward: PortForward) async {
        _ = try? await runControl(["-O", "cancel", "-L", forward.forwardSpec])
    }

    public nonisolated var controlSocketPath: String { socketPath }

    public nonisolated static let controlPersist = "10m"

    public nonisolated func masterArguments() -> [String] {
        ["-N", "-M", "-S", socketPath, "-o", "ControlPersist=\(Self.controlPersist)"]
            + baseOptions() + targetArguments()
    }

    public nonisolated func execArguments(command: String) -> [String] {
        ["-T", "-S", socketPath, "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"]
            + baseOptions() + targetArguments() + [command]
    }

    public nonisolated func terminalArguments(remoteCommand: String? = nil) -> [String] {
        var arguments = ["-tt", "-S", socketPath] + baseOptions() + targetArguments()
        if let remoteCommand {
            arguments.append(remoteCommand)
        }
        return arguments
    }

    public nonisolated func terminalEnvironment() -> [String] {
        environment().map { "\($0.key)=\($0.value)" }
    }

    private nonisolated func execProcess(command: String) -> Process {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = execArguments(command: command)
        process.environment = environment()
        return process
    }

    private func runControl(_ control: [String]) async throws -> SSHExecResult {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = ["-S", socketPath] + control + [machine.sshTarget]
        process.environment = environment()
        let stderrPipe = Pipe()
        let buffer = PipeBuffer()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        stderrPipe.fileHandleForReading.readabilityHandler = {
            PipeReading.consume($0, receive: buffer.append)
        }
        try process.run()
        let status = await Self.waitForExit(process, timeout: 10)
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        return SSHExecResult(status: status, stdout: Data(), stderr: buffer.snapshot())
    }

    private nonisolated func baseOptions() -> [String] {
        [
            "-o", "UserKnownHostsFile=\(knownHostsArgument)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=12",
        ]
    }

    private nonisolated func targetArguments() -> [String] {
        switch machine.source {
        case let .sshConfigAlias(alias):
            return [alias]
        case .manual:
            var arguments = ["-p", String(machine.port)]
            switch machine.auth {
            case .agent:
                break
            case let .keyFile(path, _):
                arguments += ["-i", SSHConfigFile.expandTilde(path), "-o", "IdentitiesOnly=yes"]
            case .password:
                arguments += [
                    "-o", "PreferredAuthentications=password,keyboard-interactive",
                    "-o", "PubkeyAuthentication=no",
                    "-o", "NumberOfPasswordPrompts=1",
                ]
            }
            arguments.append(machine.sshTarget)
            return arguments
        }
    }

    private nonisolated func environment() -> [String: String] {
        MachineSSHEnvironment.make(for: machine)
    }

    static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Int32 {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            let resumeOnce: @Sendable (Int32) -> Void = { status in
                guard gate.claim() else { return }
                continuation.resume(returning: status)
            }
            process.terminationHandler = { resumeOnce($0.terminationStatus) }
            if !process.isRunning {
                resumeOnce(process.terminationStatus)
                return
            }
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
            gate.install(timeoutWorkItem)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout, execute: timeoutWorkItem)
        }
    }

    static func friendlyConnectError(_ stderr: String) -> SSHConnectFailure {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("remote host identification has changed")
            || lowered.contains("host key verification failed")
        {
            return SSHConnectFailure(
                message: "The machine's host key changed. If this is expected, forget the pinned "
                    + "key in the machine settings and reconnect.", isRecoverable: false)
        }
        if lowered.contains("permission denied") || lowered.contains("too many authentication") {
            return SSHConnectFailure(
                message: "Authentication failed. Check the user name, key, or password.",
                isRecoverable: false)
        }
        if lowered.contains("connection refused") {
            return SSHConnectFailure(
                message: "Connection refused. Is the SSH server running on that port?",
                isRecoverable: true)
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return SSHConnectFailure(
                message: "Connection timed out. Is the machine reachable on this network?",
                isRecoverable: true)
        }
        if lowered.contains("could not resolve hostname") {
            return SSHConnectFailure(
                message: "Could not resolve the host name.", isRecoverable: true)
        }
        let lastLine = text.split(separator: "\n").last.map(String.init) ?? text
        return SSHConnectFailure(
            message: lastLine.isEmpty ? "Connection failed." : lastLine, isRecoverable: true)
    }
}
