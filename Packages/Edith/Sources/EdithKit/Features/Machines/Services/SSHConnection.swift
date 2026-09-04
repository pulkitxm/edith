import Foundation

public struct SSHExecResult: Codable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String {
        PowerShell.decodedError(
            SSHTransportDiagnostics.cleanStderr(String(decoding: stderr, as: UTF8.self)))
    }
    public var combinedText: String { stdoutText + stderrText }
    public var successfulCommandText: String { combinedText }
    public var succeeded: Bool { status == 0 }
}

enum SSHTransportDiagnostics {
    static func isMultiplexingWarning(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("mux_client_request_session: session request failed:")
    }

    static func cleanStderr(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isMultiplexingWarning(String($0)) }
            .joined(separator: "\n")
    }
}

enum SSHTransferCommands {
    static func createUploadDirectory(
        path: String, platform: RemoteMachinePlatform
    ) -> String? {
        guard platform == .windows else { return nil }
        return PowerShell.userCommand(
            "$path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("
                + "\(PowerShell.literal(path))); "
                + "$parent=[IO.Path]::GetDirectoryName($path); "
                + "if (![String]::IsNullOrWhiteSpace($parent)) { "
                + "[IO.Directory]::CreateDirectory($parent) | Out-Null }")
    }

    static func temporaryDirectory(platform: RemoteMachinePlatform) -> String? {
        guard platform == .windows else { return nil }
        return PowerShell.userCommand("[Console]::Out.Write([IO.Path]::GetTempPath())")
    }
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

struct SSHUploadAttempt: Sendable {
    let sent: Int64
    let status: Int32
    let writeSucceeded: Bool
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

public enum SSHControlSocketMode: Equatable, Sendable {
    case isolated
    case shared
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

final class PipeBuffer: @unchecked Sendable {
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
    private static let processTimeoutQueue = DispatchQueue(
        label: "com.pulkit.edith.process-timeout", qos: .userInitiated)

    public let machine: Machine
    public private(set) var remotePlatform: RemoteMachinePlatform?

    private var masterProcess: Process?
    private let socketPath: String
    private let knownHostsArgument: String
    private let taskClient: AgentTaskClient?

    public init(
        machine: Machine, controlSocketMode: SSHControlSocketMode = .isolated,
        taskClient: AgentTaskClient? = nil
    ) {
        self.machine = machine
        self.taskClient = taskClient
        let connectionID = controlSocketMode == .isolated ? UUID() : nil
        socketPath = MachinePaths.socketFile(for: machine.id, connectionID: connectionID).path
        let userKnownHosts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts").path
        knownHostsArgument =
            "\"\(MachinePaths.knownHostsFile.path)\" \"\(userKnownHosts)\""
    }

    public nonisolated static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    public func connect() async throws {
        if await masterIsAlive() {
            if remotePlatform == nil { try await validatePlatform() }
            return
        }
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
            if FileManager.default.fileExists(atPath: socketPath), await masterIsAlive() {
                try await validatePlatform()
                return
            }
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

    private func validatePlatform() async throws {
        let unixResult = try await run("uname -s", timeout: 10)
        var platform =
            unixResult.succeeded
            ? RemoteMachinePlatform.unixName(unixResult.stdoutText) : nil
        if platform == nil {
            let windowsResult = try await run(
                PowerShell.command("[Console]::Out.Write($env:OS)"), timeout: 10)
            if windowsResult.succeeded {
                platform = RemoteMachinePlatform.windowsName(windowsResult.stdoutText)
            }
        }
        guard let platform else {
            await disconnect()
            throw SSHConnectionError.connectFailed(
                SSHConnectFailure(
                    message: "Edith supports remote macOS, Linux and Windows machines.",
                    isRecoverable: false))
        }
        remotePlatform = platform
    }

    nonisolated static func supportsPlatform(_ name: String) -> Bool {
        RemoteMachinePlatform.unixName(name) != nil
            || RemoteMachinePlatform.windowsName(name) != nil
    }

    public func disconnect() async {
        _ = try? await runControl(["-O", "exit"])
        masterProcess?.terminate()
        masterProcess = nil
        remotePlatform = nil
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
        if AgentCommandRouting.isEnabled || taskClient != nil {
            try await (taskClient ?? AgentTaskClient()).transferMachineFile(
                AgentMachineTransferRequest(
                    machine: machine, direction: .download, localURL: localURL,
                    remotePath: remotePath), progress: progress)
            return
        }
        let command =
            remotePlatform == .windows
            ? PowerShell.command(
                "$path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("
                    + "\(PowerShell.literal(remotePath))); "
                    + "$bytes=[IO.File]::ReadAllBytes($path); "
                    + "$output=[Console]::OpenStandardOutput(); "
                    + "$output.Write($bytes,0,$bytes.Length); $output.Flush()")
            : "cat \(ShellQuote.quote(remotePath))"
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
        let status: Int32
        do {
            status = try await Self.receiveDownload(
                process: process, reader: reader, output: output, localURL: localURL,
                progress: progress)
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard status == 0 else {
            try? FileManager.default.removeItem(at: localURL)
            let message = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHConnectionError.transferFailed(
                message.isEmpty ? "Download failed." : message)
        }
    }

    static func receiveDownload(
        process: Process, reader: FileHandle, output: FileHandle, localURL: URL,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int32 {
        do {
            return try await withTaskCancellationHandler {
                var written: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let chunk = reader.readData(ofLength: 128 * 1024)
                    if chunk.isEmpty { break }
                    try Task.checkCancellation()
                    output.write(chunk)
                    written += Int64(chunk.count)
                    progress?(written)
                }
                try? output.close()
                process.waitUntilExit()
                try Task.checkCancellation()
                return process.terminationStatus
            } onCancel: {
                if process.isRunning { process.terminate() }
                try? reader.close()
            }
        } catch {
            try? output.close()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    public func upload(
        localURL: URL, toRemotePath remotePath: String,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        if AgentCommandRouting.isEnabled || taskClient != nil {
            try await (taskClient ?? AgentTaskClient()).transferMachineFile(
                AgentMachineTransferRequest(
                    machine: machine, direction: .upload, localURL: localURL,
                    remotePath: remotePath), progress: progress)
            return
        }
        guard FileManager.default.isReadableFile(atPath: localURL.path) else {
            throw SSHConnectionError.transferFailed("Could not read the local file.")
        }
        let expected =
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64
            ?? -1
        if remotePlatform == .windows {
            try await uploadToWindows(
                localURL: localURL, remotePath: remotePath, expected: expected,
                progress: progress)
            return
        }
        guard let input = try? FileHandle(forReadingFrom: localURL) else {
            throw SSHConnectionError.transferFailed("Could not read the local file.")
        }
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
        let attempt: SSHUploadAttempt
        do {
            attempt = try await Self.sendUpload(
                process: process, input: input, writer: writer, progress: progress)
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            await discard(remotePath)
            throw error
        }
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let reported = SSHExecResult(
            status: attempt.status, stdout: Data(), stderr: stderrBuffer.snapshot()
        ).stderrText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard attempt.writeSucceeded else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                reported.isEmpty
                    ? "The machine stopped accepting the file after \(attempt.sent) bytes."
                    : reported)
        }
        guard attempt.status == 0 else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(reported.isEmpty ? "Upload failed." : reported)
        }
        guard expected < 0 || attempt.sent == expected else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                "Only \(attempt.sent) of \(expected) bytes were sent.")
        }
        guard let landed = await remoteSize(remotePath), landed == attempt.sent else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                "The machine kept a different file than the one that was sent.")
        }
    }

    private func uploadToWindows(
        localURL: URL, remotePath: String, expected: Int64,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        if let command = SSHTransferCommands.createUploadDirectory(
            path: remotePath, platform: .windows)
        {
            try await runChecked(command, timeout: 30)
        }
        progress?(0)
        let result = await LocalMachineCommandExecution.run(
            executable: URL(fileURLWithPath: "/usr/bin/scp"),
            arguments:
                fileTransferArguments()
                + [localURL.path, "\(machine.sshTarget):\(windowsSFTPPath(remotePath))"],
            environment: environment(), commandLabel: "scp", timeout: 15 * 60)
        if case let .failure(error) = result {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(error.localizedDescription)
        }
        guard let landed = await remoteSize(remotePath), expected < 0 || landed == expected else {
            await discard(remotePath)
            throw SSHConnectionError.transferFailed(
                "The machine kept a different file than the one that was sent.")
        }
        if expected >= 0 { progress?(expected) }
    }

    public func temporaryDirectory() async throws -> String {
        let platform = remotePlatform ?? .linux
        guard let command = SSHTransferCommands.temporaryDirectory(platform: platform) else {
            return "/tmp"
        }
        let result = try await runChecked(command, timeout: 15)
        let path = result.successfulCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileListing.isWindowsPath(path) else {
            throw SSHConnectionError.transferFailed(
                "The machine did not provide a usable temporary directory.")
        }
        return path
    }

    static func sendUpload(
        process: Process, input: FileHandle, writer: FileHandle,
        timeout: TimeInterval = 15 * 60, progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> SSHUploadAttempt {
        signal(SIGPIPE, SIG_IGN)
        return try await withTaskCancellationHandler {
            var sent: Int64 = 0
            var writeSucceeded = true
            while true {
                try Task.checkCancellation()
                let chunk = input.readData(ofLength: 128 * 1024)
                if chunk.isEmpty { break }
                do {
                    try writer.write(contentsOf: chunk)
                } catch {
                    writeSucceeded = false
                    break
                }
                sent += Int64(chunk.count)
                progress?(sent)
            }
            try? writer.close()
            try? input.close()
            if Task.isCancelled {
                if process.isRunning { process.terminate() }
                _ = await waitForExit(process, timeout: 1, killDelay: 1)
                throw CancellationError()
            }
            let status = await waitForExit(process, timeout: timeout)
            try Task.checkCancellation()
            return SSHUploadAttempt(
                sent: sent, status: status, writeSucceeded: writeSucceeded)
        } onCancel: {
            try? input.close()
            try? writer.close()
            if process.isRunning { process.terminate() }
        }
    }

    public func remoteFileSize(_ path: String) async -> Int64? {
        await remoteSize(path)
    }

    private func remoteSize(_ path: String) async -> Int64? {
        let command: String
        if remotePlatform == .windows {
            command = PowerShell.command(
                "[Console]::Out.Write((Get-Item -LiteralPath "
                    + "\(PowerShell.literal(path))).Length)")
        } else {
            let quoted = ShellQuote.quote(path)
            command = "stat -c%s \(quoted) 2>/dev/null || stat -f%z \(quoted) 2>/dev/null"
        }
        guard let result = try? await run(command, timeout: 30), result.succeeded else {
            return nil
        }
        return Int64(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func discard(_ path: String) async {
        let command =
            remotePlatform == .windows
            ? PowerShell.command(
                "Remove-Item -LiteralPath \(PowerShell.literal(path)) -Force "
                    + "-ErrorAction SilentlyContinue")
            : "rm -f \(ShellQuote.quote(path))"
        _ = try? await run(command, timeout: 30)
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

    private nonisolated func fileTransferArguments() -> [String] {
        var arguments =
            [
                "-q", "-o", "ControlPath=\"\(socketPath)\"", "-o", "BatchMode=yes", "-o",
                "LogLevel=ERROR",
            ] + baseOptions()
        switch machine.source {
        case .sshConfigAlias:
            break
        case .manual:
            arguments += ["-P", String(machine.port)]
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
        }
        return arguments
    }

    private nonisolated func windowsSFTPPath(_ path: String) -> String {
        "/" + path.replacingOccurrences(of: "\\", with: "/")
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

    static func waitForExit(
        _ process: Process, timeout: TimeInterval, killDelay: TimeInterval = 2
    ) async -> Int32 {
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
                    processTimeoutQueue.asyncAfter(deadline: .now() + killDelay) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
            gate.install(timeoutWorkItem)
            processTimeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
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
        let lastLine =
            text.split(whereSeparator: \Character.isNewline).last.map(String.init) ?? text
        return SSHConnectFailure(
            message: lastLine.isEmpty ? "Connection failed." : lastLine, isRecoverable: true)
    }
}
