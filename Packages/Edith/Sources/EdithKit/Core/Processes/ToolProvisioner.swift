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
    public let discardsStandardError: Bool
    public let terminatesProcessGroup: Bool

    public init(
        executableURL: URL, arguments: [String], environment: [String: String],
        currentDirectoryURL: URL? = nil, timeout: TimeInterval? = nil,
        maximumOutputBytes: Int? = nil,
        discardsStandardError: Bool = false, terminatesProcessGroup: Bool = false
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
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
    private var exceededLimit = false

    init(maximumBytes: Int?) {
        self.maximumBytes = maximumBytes
    }

    func receive(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return [] }
        if let maximumBytes, complete.count + data.count > maximumBytes {
            complete.removeAll(keepingCapacity: false)
            pending = ""
            exceededLimit = true
            return []
        }
        complete.append(data)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        pending += text.replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    func finish() -> (lines: [String], output: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let lines = exceededLimit || pending.isEmpty ? [] : [pending]
        pending = ""
        return (lines, complete, exceededLimit)
    }
}

public enum CLICommandRunner {
    private static let terminationGrace: TimeInterval = 0.25
    private static let processGroupScript = """
        set -m
        "$@" &
        child=$!
        set +m
        terminate_group() {
            if kill -TERM -"$child" 2>/dev/null; then
                sleep 0.1
                kill -KILL -"$child" 2>/dev/null || :
            fi
        }
        trap 'terminate_group; exit 124' TERM INT
        wait "$child"
        status=$?
        terminate_group
        trap - TERM INT
        exit "$status"
        """

    public static func run(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        try await Task.detached(priority: .utility) {
            try runBlocking(request, onLine: onLine)
        }.value
    }

    private static func runBlocking(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> CLICommandResult {
        let process = Process()
        if request.terminatesProcessGroup {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments =
                [
                    "-c", processGroupScript, "edith-process", request.executableURL.path,
                ] + request.arguments
        } else {
            process.executableURL = request.executableURL
            process.arguments = request.arguments
        }
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = request.discardsStandardError ? FileHandle.nullDevice : pipe
        let output = CLIStreamingOutput(maximumBytes: request.maximumOutputBytes)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4_096)
                guard !chunk.isEmpty else { break }
                for line in output.receive(chunk) { onLine(line) }
            }
            readerFinished.signal()
        }

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processFinished.signal() }
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = readerFinished.wait(timeout: .now() + terminationGrace)
            throw CLICommandRunnerError.launchFailed
        }

        if let timeout = request.timeout,
            processFinished.wait(timeout: .now() + max(0, timeout)) == .timedOut
        {
            process.terminate()
            if processFinished.wait(timeout: .now() + terminationGrace) == .timedOut,
                process.isRunning
            {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + terminationGrace)
            }
            _ = readerFinished.wait(timeout: .now() + terminationGrace)
            throw CLICommandRunnerError.timedOut
        } else if request.timeout == nil {
            processFinished.wait()
        }

        guard readerFinished.wait(timeout: .now() + terminationGrace) == .success else {
            throw CLICommandRunnerError.streamFailed
        }
        let finished = output.finish()
        guard !finished.exceededLimit else {
            throw CLICommandRunnerError.outputLimitExceeded
        }
        for line in finished.lines { onLine(line) }
        return CLICommandResult(
            terminationStatus: process.terminationStatus,
            outputData: finished.output)
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
