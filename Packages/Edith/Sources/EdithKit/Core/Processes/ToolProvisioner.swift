import Darwin
import Foundation
import Observation

public struct CLICommandRequest: Equatable, Sendable {
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

public struct CLICommandResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let outputData: Data
    public var output: String { String(decoding: outputData, as: UTF8.self) }

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        self.outputData = Data(output.utf8)
    }

    public init(terminationStatus: Int32, outputData: Data) {
        self.terminationStatus = terminationStatus
        self.outputData = outputData
    }
}

public struct CLICommandCapturedResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutputData: Data
    public let standardErrorData: Data

    public init(
        terminationStatus: Int32, standardOutputData: Data, standardErrorData: Data
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutputData = standardOutputData
        self.standardErrorData = standardErrorData
    }

    public var standardOutput: String {
        String(decoding: standardOutputData, as: UTF8.self)
    }

    public var standardError: String {
        String(decoding: standardErrorData, as: UTF8.self)
    }

    fileprivate var combined: CLICommandResult {
        CLICommandResult(
            terminationStatus: terminationStatus,
            outputData: standardOutputData + standardErrorData)
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
    private var pending = ""
    private var complete = Data()
    private var completeLines: [String] = []
    private var exceededLimit = false

    init(maximumBytes: Int?) {
        self.maximumBytes = maximumBytes
    }

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        if let maximumBytes, complete.count + data.count > maximumBytes {
            complete.removeAll(keepingCapacity: false)
            completeLines.removeAll(keepingCapacity: false)
            pending = ""
            exceededLimit = true
            return
        }
        complete.append(data)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        pending += text.replacingOccurrences(of: "\r", with: "\n")
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if !line.isEmpty { completeLines.append(line) }
        }
    }

    func finish() -> (lines: [String], output: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if !exceededLimit, !pending.isEmpty { completeLines.append(pending) }
        pending = ""
        return (completeLines, complete, exceededLimit)
    }

    var hasExceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }
}

public enum CLICommandRunner {
    private static let terminationGrace: TimeInterval = 0.25
    private static let lifecyclePoll: TimeInterval = 0.01
    private static let processGroupScript = """
        group_file=$1
        shift
        child=
        stop_requested=0
        terminate_group() {
            trap - TERM INT
            [ -n "$child" ] || return
            kill -TERM -"$child" 2>/dev/null || :
            sleep 0.1
            kill -KILL -"$child" 2>/dev/null || :
        }
        request_stop() {
            stop_requested=1
            [ -n "$child" ] || return
            terminate_group
            exit 124
        }
        trap 'request_stop' TERM INT
        set -m
        "$@" &
        child=$!
        set +m
        printf '%s\n' "$child" > "$group_file"
        [ "$stop_requested" -eq 0 ] || { terminate_group; exit 124; }
        wait "$child"
        status=$?
        terminate_group
        exit "$status"
        """

    public static func run(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        let worker = Task.detached(priority: .utility) {
            try runBlocking(request, onLine: onLine)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func runSeparated(
        _ request: CLICommandRequest,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        let worker = Task.detached(priority: .utility) {
            try runBlockingCaptured(
                request, onStandardOutputLine: onStandardOutputLine,
                onStandardErrorLine: onStandardErrorLine
            ).combined
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func runCaptured(
        _ request: CLICommandRequest,
        onStandardOutputLine: @escaping @Sendable (String) -> Void = { _ in },
        onStandardErrorLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CLICommandCapturedResult {
        let worker = Task.detached(priority: .utility) {
            try runBlockingCaptured(
                request, onStandardOutputLine: onStandardOutputLine,
                onStandardErrorLine: onStandardErrorLine)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runBlocking(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> CLICommandResult {
        try runBlockingCaptured(
            request, onStandardOutputLine: onLine, onStandardErrorLine: onLine
        ).combined
    }
    private static func runBlockingCaptured(
        _ request: CLICommandRequest,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) throws -> CLICommandCapturedResult {
        let process = Process()
        let deadline = request.timeout.map {
            ProcessInfo.processInfo.systemUptime + max(0, $0)
        }
        let cancellationRequested: @Sendable () -> Bool = { Task.isCancelled }
        let processGroupEscalationSignal = SIGKILL
        let groupFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-process-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: groupFile) }
        if request.terminatesProcessGroup {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments =
                [
                    "-c", processGroupScript, "edith-process", groupFile.path,
                    request.executableURL.path,
                ] + request.arguments
        } else {
            process.executableURL = request.executableURL
            process.arguments = request.arguments
        }
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        let input = request.standardInputData.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError =
            request.discardsStandardError ? FileHandle.nullDevice : standardError
        let output = CLIStreamingOutput(maximumBytes: request.maximumOutputBytes)
        let error = CLIStreamingOutput(maximumBytes: request.maximumOutputBytes)
        let outputFinished = DispatchSemaphore(value: 0)
        let errorFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = standardOutput.fileHandleForReading.readData(ofLength: 4_096)
                guard !chunk.isEmpty else { break }
                output.receive(chunk)
            }
            outputFinished.signal()
        }
        if request.discardsStandardError {
            errorFinished.signal()
        } else {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = standardError.fileHandleForReading.readData(ofLength: 4_096)
                    guard !chunk.isEmpty else { break }
                    error.receive(chunk)
                }
                errorFinished.signal()
            }
        }

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processFinished.signal() }
        do {
            try process.run()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
        } catch {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
            try? input?.fileHandleForWriting.close()
            _ = drain(standardOutput, readerFinished: outputFinished)
            _ = drain(standardError, readerFinished: errorFinished)
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
        while true {
            if cancellationRequested() {
                stop = .cancelled
                break
            }
            if output.hasExceededLimit || error.hasExceededLimit {
                stop = .outputLimitExceeded
                break
            }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                stop = .timedOut
                break
            }
            if processFinished.wait(timeout: .now() + lifecyclePoll) == .success { break }
        }

        if let stop {
            try? input?.fileHandleForWriting.close()
            terminateProcessGroup(
                process, groupFile: request.terminatesProcessGroup ? groupFile : nil,
                processFinished: processFinished,
                escalationSignal: processGroupEscalationSignal)
            _ = drain(standardOutput, readerFinished: outputFinished)
            _ = drain(standardError, readerFinished: errorFinished)
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

        guard drain(standardOutput, readerFinished: outputFinished),
            drain(standardError, readerFinished: errorFinished)
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
        for line in finishedOutput.lines { onStandardOutputLine(line) }
        for line in finishedError.lines { onStandardErrorLine(line) }
        return CLICommandCapturedResult(
            terminationStatus: process.terminationStatus,
            standardOutputData: finishedOutput.output,
            standardErrorData: finishedError.output)
    }

    private enum StopReason {
        case cancelled
        case timedOut
        case outputLimitExceeded
    }

    private static func terminateProcessGroup(
        _ process: Process, groupFile: URL?, processFinished: DispatchSemaphore,
        escalationSignal: Int32
    ) {
        var group = groupFile.flatMap {
            groupIdentifier(at: $0, waitingUntil: ProcessInfo.processInfo.systemUptime + 0.05)
        }
        if let group {
            _ = kill(-group, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        _ = processFinished.wait(timeout: .now() + terminationGrace)
        if group == nil, let groupFile {
            group = groupIdentifier(at: groupFile, waitingUntil: nil)
        }
        if let group { _ = kill(-group, escalationSignal) }
        if process.isRunning { _ = kill(process.processIdentifier, escalationSignal) }
        _ = processFinished.wait(timeout: .now() + terminationGrace)
    }

    private static func groupIdentifier(at url: URL, waitingUntil deadline: TimeInterval?) -> Int32?
    {
        repeat {
            if let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                let value = Int32(text), value > 1
            {
                return value
            }
            guard let deadline, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            usleep(5_000)
        } while true
    }

    @discardableResult
    private static func drain(_ pipe: Pipe, readerFinished: DispatchSemaphore) -> Bool {
        if readerFinished.wait(timeout: .now() + terminationGrace) == .success { return true }
        try? pipe.fileHandleForReading.close()
        return readerFinished.wait(timeout: .now() + terminationGrace) == .success
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
