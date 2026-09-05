import Darwin
import Foundation
import Observation

public struct CLICommandRequest: Codable, Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL?
    public let timeout: TimeInterval?
    public let maximumOutputBytes: Int?
    public let standardInputData: Data?
    public let discardsStandardError: Bool
    public let terminatesProcessGroup: Bool

    public init(
        executableURL: URL, arguments: [String], environment: [String: String],
        currentDirectoryURL: URL? = nil, timeout: TimeInterval? = nil,
        maximumOutputBytes: Int? = nil,
        standardInputData: Data? = nil,
        discardsStandardError: Bool = false, terminatesProcessGroup: Bool = false
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.standardInputData = standardInputData
        self.discardsStandardError = discardsStandardError
        self.terminatesProcessGroup = terminatesProcessGroup
    }
}

public enum ToolVersionProbe {
    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult

    public static func version(
        _ request: CLICommandRequest,
        runCommand: @escaping RunCommand = { try await CLICommandRunner.run($0, onLine: $1) }
    ) async -> String? {
        guard let result = try? await runCommand(request, { _ in }), result.terminationStatus == 0
        else { return nil }
        return result.output.components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? request.executableURL.lastPathComponent
    }
}

public struct CLICommandResult: Codable, Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutputData: Data
    public let standardErrorData: Data
    public var outputData: Data { standardOutputData + standardErrorData }
    public var output: String { String(decoding: outputData, as: UTF8.self) }
    public var standardOutput: String { String(decoding: standardOutputData, as: UTF8.self) }
    public var standardError: String { String(decoding: standardErrorData, as: UTF8.self) }

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        standardOutputData = Data(output.utf8)
        standardErrorData = Data()
    }

    public init(terminationStatus: Int32, outputData: Data) {
        self.terminationStatus = terminationStatus
        standardOutputData = outputData
        standardErrorData = Data()
    }

    public init(terminationStatus: Int32, standardOutputData: Data, standardErrorData: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutputData = standardOutputData
        self.standardErrorData = standardErrorData
    }
}

public enum CLICommandRunnerError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
    case streamFailed
}

public enum CLIToolProvisionState: Equatable, Sendable {
    case idle
    case checking
    case present(version: String)
    case installing(logTail: [String])
    case installed
    case failed(message: String, instruction: String)
}

private final class CLIStreamingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int?
    private let onLine: (@Sendable (String) -> Void)?
    private var pending = Data()
    private var complete = Data()
    private var exceededLimit = false
    private var readFailed = false

    init(maximumBytes: Int?, onLine: (@Sendable (String) -> Void)?) {
        self.maximumBytes = maximumBytes
        self.onLine = onLine
    }

    func receive(_ data: Data) {
        let lines = lock.withLock { () -> [String] in
            guard !exceededLimit else { return [] }
            if let maximumBytes, complete.count + data.count > maximumBytes {
                complete.removeAll(keepingCapacity: false)
                pending.removeAll(keepingCapacity: false)
                exceededLimit = true
                return []
            }
            complete.append(data)
            guard onLine != nil else { return [] }
            var lines: [String] = []
            var start = data.startIndex
            for index in data.indices where data[index] == 10 || data[index] == 13 {
                pending.append(data[start..<index])
                if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
                start = data.index(after: index)
            }
            pending.append(data[start..<data.endIndex])
            return lines
        }
        for line in lines { onLine?(line) }
    }

    func finish() -> (output: Data, exceededLimit: Bool) {
        let finished = lock.withLock { () -> (String?, Data, Bool) in
            let line =
                !exceededLimit && !pending.isEmpty ? String(decoding: pending, as: UTF8.self) : nil
            pending.removeAll(keepingCapacity: false)
            return (line, complete, exceededLimit)
        }
        if let line = finished.0 { onLine?(line) }
        return (finished.1, finished.2)
    }

    var hasExceededLimit: Bool { lock.withLock { exceededLimit } }
    var hasReadFailure: Bool { lock.withLock { readFailed } }
    func recordReadFailure() { lock.withLock { readFailed = true } }
}

private final class CLIProcessOutputReader: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let output: CLIStreamingOutput

    init(handle: FileHandle, output: CLIStreamingOutput) {
        self.descriptor = handle.fileDescriptor
        self.output = output
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [finished] in
            try? handle.close()
            finished.signal()
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
            output.recordReadFailure()
            source.cancel()
        }
        source.activate()
    }

    func cancel() { source.cancel() }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                output.receive(Data(buffer.prefix(count)))
                if output.hasExceededLimit {
                    source.cancel()
                    return
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                if count < 0 { output.recordReadFailure() }
                source.cancel()
                return
            }
        }
    }

    deinit { source.cancel() }
}

private final class CLICommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

public enum CLICommandRunner {
    private static let terminationGrace: TimeInterval = 0.25
    private static let lifecyclePoll: TimeInterval = 0.01

    public static func run(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        if AgentCommandRouting.isEnabled {
            return try await AgentTaskClient().runCommand(
                request, onStandardOutputLine: onLine, onStandardErrorLine: onLine)
        }
        return try await runLocalSeparated(
            request, onStandardOutputLine: onLine, onStandardErrorLine: onLine)
    }

    public static func runLocal(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        try await runLocalSeparated(
            request, onStandardOutputLine: onLine, onStandardErrorLine: onLine)
    }

    public static func runSeparated(
        _ request: CLICommandRequest,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        if AgentCommandRouting.isEnabled {
            return try await AgentTaskClient().runCommand(
                request, onStandardOutputLine: onStandardOutputLine,
                onStandardErrorLine: onStandardErrorLine)
        }
        return try await runLocalSeparated(
            request, onStandardOutputLine: onStandardOutputLine,
            onStandardErrorLine: onStandardErrorLine)
    }

    public static func runLocalSeparated(
        _ request: CLICommandRequest, streamsWhileRunning: Bool = false,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        let cancellation = CLICommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let result = try runBlockingSeparated(
                            request, streamsWhileRunning: streamsWhileRunning,
                            onStandardOutputLine: onStandardOutputLine,
                            onStandardErrorLine: onStandardErrorLine,
                            cancellationRequested: { cancellation.isCancelled })
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runBlockingSeparated(
        _ request: CLICommandRequest, streamsWhileRunning: Bool = false,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws -> CLICommandResult {
        let deadline = request.timeout.map {
            ProcessInfo.processInfo.systemUptime + max(0, $0)
        }
        let input = request.standardInputData.map { _ in Pipe() }

        let standardOutput = Pipe()
        let standardError = Pipe()
        let output = CLIStreamingOutput(
            maximumBytes: request.maximumOutputBytes,
            onLine: streamsWhileRunning ? onStandardOutputLine : nil)
        let error = CLIStreamingOutput(
            maximumBytes: request.maximumOutputBytes,
            onLine: streamsWhileRunning ? onStandardErrorLine : nil)
        let outputReader = CLIProcessOutputReader(
            handle: standardOutput.fileHandleForReading, output: output)
        let errorReader =
            request.discardsStandardError
            ? nil
            : CLIProcessOutputReader(
                handle: standardError.fileHandleForReading, output: error)

        let processFinished = DispatchSemaphore(value: 0)
        let process: CLIChildProcess
        do {
            if cancellationRequested() { throw CancellationError() }
            process = try CLIChildProcess(
                request: request,
                input: input?.fileHandleForReading.fileDescriptor
                    ?? FileHandle.nullDevice.fileDescriptor,
                output: standardOutput.fileHandleForWriting.fileDescriptor,
                error: request.discardsStandardError
                    ? FileHandle.nullDevice.fileDescriptor
                    : standardError.fileHandleForWriting.fileDescriptor,
                onExit: { processFinished.signal() })
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
        } catch {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
            try? input?.fileHandleForWriting.close()
            _ = drain(outputReader)
            _ = drain(errorReader)
            if error is CancellationError { throw error }
            throw CLICommandRunnerError.launchFailed
        }
        let inputFinished = DispatchSemaphore(value: 0)
        if let data = request.standardInputData, let input {
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
                inputFinished.signal()
            }
        } else {
            inputFinished.signal()
        }

        var stop: StopReason?
        polling: while true {
            if cancellationRequested() {
                stop = .cancelled
                break
            }
            if output.hasExceededLimit || error.hasExceededLimit {
                stop = .outputLimitExceeded
                break
            }
            switch pollForExit(processFinished, deadline: deadline) {
            case .finished: break polling
            case .timedOut: stop = .timedOut; break polling
            case .running: continue
            }
        }

        if let stop {
            try? input?.fileHandleForWriting.close()
            terminateProcessGroup(process, processFinished: processFinished)
            _ = drain(outputReader)
            _ = drain(errorReader)
            _ = inputFinished.wait(timeout: .now() + terminationGrace)
            switch stop {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw CLICommandRunnerError.timedOut
            case .outputLimitExceeded:
                throw CLICommandRunnerError.outputLimitExceeded
            }
        }

        if process.ownsProcessGroup, process.groupIsAlive {
            terminateProcessGroup(process, processFinished: processFinished)
        }
        guard drain(outputReader),
            drain(errorReader)
        else { throw CLICommandRunnerError.streamFailed }
        guard inputFinished.wait(timeout: .now() + terminationGrace) == .success else {
            try? input?.fileHandleForWriting.close()
            throw CLICommandRunnerError.streamFailed
        }
        let finishedOutput = output.finish()
        let finishedError = error.finish()
        guard !finishedOutput.exceededLimit, !finishedError.exceededLimit else {
            throw CLICommandRunnerError.outputLimitExceeded
        }
        guard !output.hasReadFailure, !error.hasReadFailure else {
            throw CLICommandRunnerError.streamFailed
        }
        if !streamsWhileRunning {
            for line in String(decoding: finishedOutput.output, as: UTF8.self).split(
                whereSeparator: \.isNewline)
            {
                onStandardOutputLine(String(line))
            }
            for line in String(decoding: finishedError.output, as: UTF8.self).split(
                whereSeparator: \.isNewline)
            {
                onStandardErrorLine(String(line))
            }
        }
        return CLICommandResult(
            terminationStatus: process.terminationStatus,
            standardOutputData: finishedOutput.output,
            standardErrorData: finishedError.output)
    }

    enum ExitPollResult: Equatable { case finished, timedOut, running }

    static func pollForExit(_ finished: DispatchSemaphore, deadline: TimeInterval?)
        -> ExitPollResult
    {
        if finished.wait(timeout: .now()) == .success { return .finished }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
        return finished.wait(timeout: .now() + lifecyclePoll) == .success ? .finished : .running
    }

    private enum StopReason {
        case cancelled
        case timedOut
        case outputLimitExceeded
    }

    private static func terminateProcessGroup(
        _ process: CLIChildProcess, processFinished: DispatchSemaphore
    ) {
        process.signal(SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + terminationGrace
        while process.groupIsAlive, ProcessInfo.processInfo.systemUptime < deadline {
            _ = processFinished.wait(timeout: .now() + lifecyclePoll)
        }
        if process.groupIsAlive { process.signal(SIGKILL) }
        if process.isRunning { _ = processFinished.wait(timeout: .now() + terminationGrace) }
    }

    @discardableResult
    private static func drain(_ reader: CLIProcessOutputReader?) -> Bool {
        guard let reader else { return true }
        if reader.finished.wait(timeout: .now() + terminationGrace) == .success { return true }
        reader.cancel()
        return reader.finished.wait(timeout: .now() + terminationGrace) == .success
    }
}

@MainActor
@Observable
public final class ToolProvisioner {
    public typealias RunCommand =
        @Sendable (
            CLICommandRequest, @escaping @Sendable (String) -> Void
        ) async throws -> CLICommandResult

    public static let shared = ToolProvisioner()

    public private(set) var states: [String: CLIToolProvisionState] = [:]
    public private(set) var logs: [String: [String]] = [:]

    private let installer: ToolInstaller
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        runCommand: @escaping RunCommand = { request, onLine in
            try await CLICommandRunner.run(request, onLine: onLine)
        }
    ) {
        self.installer = ToolInstaller(runCommand: runCommand)
    }

    public func state(for tool: CLIToolSpec) -> CLIToolProvisionState {
        states[tool.id] ?? .idle
    }

    @discardableResult
    public func check(_ tool: CLIToolSpec) -> Task<Void, Never> {
        start(tool, installIfMissing: false)
    }

    @discardableResult
    public func provision(_ tool: CLIToolSpec) -> Task<Void, Never> {
        start(tool, installIfMissing: true)
    }

    public func provision(_ tools: [CLIToolSpec]) {
        for tool in tools { provision(tool) }
    }

    private func start(_ tool: CLIToolSpec, installIfMissing: Bool) -> Task<Void, Never> {
        if let task = tasks[tool.id] { return task }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(tool, installIfMissing: installIfMissing)
            self.tasks[tool.id] = nil
        }
        tasks[tool.id] = task
        return task
    }

    private func perform(_ tool: CLIToolSpec, installIfMissing: Bool) async {
        states[tool.id] = .checking
        logs[tool.id] = []
        let record = recorder(for: tool)
        if let version = await installer.detectedVersion(of: tool, log: record) {
            states[tool.id] = .present(version: version)
            return
        }
        guard installIfMissing else {
            states[tool.id] = .failed(
                message: tool.displayName + " is not installed",
                instruction: tool.installStrategy.instruction)
            return
        }
        states[tool.id] = .installing(logTail: [])
        append("Installing " + tool.displayName + "...", for: tool)
        do {
            _ = try await installer.install(tool, log: record)
            states[tool.id] = .installed
            append(tool.displayName + " is ready.", for: tool)
            NotificationCenter.default.post(
                name: .cliToolProvisioned, object: nil, userInfo: ["toolID": tool.id])
        } catch {
            let message =
                (error as? ToolInstallFailure)?.description
                ?? error.localizedDescription
            append(message, for: tool)
            states[tool.id] = .failed(
                message: message, instruction: tool.installStrategy.instruction)
        }
    }

    private func recorder(for tool: CLIToolSpec) -> ToolInstaller.Log {
        { [weak self] line in
            Task { @MainActor in self?.append(line, for: tool) }
        }
    }

    private func append(_ line: String, for tool: CLIToolSpec) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var toolLogs = logs[tool.id, default: []]
        toolLogs.append(trimmed)
        if toolLogs.count > 200 { toolLogs.removeFirst(toolLogs.count - 200) }
        logs[tool.id] = toolLogs
        if case .installing = states[tool.id] {
            states[tool.id] = .installing(logTail: Array(toolLogs.suffix(12)))
        }
    }
}
