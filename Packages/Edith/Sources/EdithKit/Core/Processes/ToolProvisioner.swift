import Foundation
import Observation

public struct CLICommandRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executableURL: URL, arguments: [String], environment: [String: String]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

public struct CLICommandResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let output: String

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        self.output = output
    }
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
    private var pending = ""
    private var complete = ""

    func receive(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        complete += text
        pending += text.replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    func finish() -> (lines: [String], output: String) {
        lock.lock()
        defer { lock.unlock() }
        let lines = pending.isEmpty ? [] : [pending]
        pending = ""
        return (lines, complete)
    }
}

public enum CLICommandRunner {
    public static func run(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let output = CLIStreamingOutput()
            process.executableURL = request.executableURL
            process.arguments = request.arguments
            process.environment = request.environment
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                PipeReading.consume(handle) { data in
                    for line in output.receive(data) { onLine(line) }
                }
            }
            process.terminationHandler = { completedProcess in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                for line in output.receive(remaining) { onLine(line) }
                let finished = output.finish()
                for line in finished.lines { onLine(line) }
                continuation.resume(
                    returning: CLICommandResult(
                        terminationStatus: completedProcess.terminationStatus,
                        output: finished.output))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
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
