import Foundation

public struct AgentTaskClient: Sendable {
    public let client: AgentClient
    private let pollInterval: TimeInterval

    public init(client: AgentClient = .shared, pollInterval: TimeInterval = 0.25) {
        self.client = client
        self.pollInterval = max(0.01, pollInterval)
    }

    public func submit(_ request: AgentTaskSubmission) async throws -> AgentTaskSnapshot {
        try AgentPayload.decode(
            AgentTaskSnapshot.self,
            from: await client.performInternalAsync(
                AgentTaskOperation.submit, payload: AgentPayload.encode(request)))
    }

    public func status(_ id: UUID) async throws -> AgentTaskStatus {
        try AgentPayload.decode(
            AgentTaskStatus.self,
            from: await client.performInternalAsync(
                AgentTaskOperation.status, payload: AgentPayload.encode(AgentTaskIDRequest(id: id)))
        )
    }

    public func cancel(_ id: UUID) async throws -> AgentTaskSnapshot {
        try AgentPayload.decode(
            AgentTaskSnapshot.self,
            from: await client.performInternalAsync(
                AgentTaskOperation.cancel, payload: AgentPayload.encode(AgentTaskIDRequest(id: id)))
        )
    }

    public func snapshots() async throws -> [AgentTaskSnapshot] {
        try AgentPayload.decode(
            [AgentTaskSnapshot].self,
            from: await client.performInternalAsync(AgentTaskOperation.list))
    }

    public func wait(
        _ id: UUID, onOutput: @escaping @Sendable (AgentTaskOutput) -> Void = { _ in }
    ) async throws -> Data {
        var sequence = 0
        var previousState: AgentTaskState?
        var delay = pollInterval
        while true {
            try Task.checkCancellation()
            let state: AgentTaskStatus
            do {
                state = try await status(id)
            } catch let error as AgentError where error.kind == .unavailable {
                try await Task.sleep(for: .seconds(1))
                continue
            }
            let previousSequence = sequence
            for output in state.output where output.sequence > sequence {
                onOutput(output)
                sequence = output.sequence
            }
            if state.snapshot.state == .succeeded { return state.result ?? Data() }
            if state.snapshot.state == .cancelled { throw CancellationError() }
            if state.snapshot.state.isTerminal {
                throw AgentTaskFailure(snapshot: state.snapshot, result: state.result)
            }
            if previousState == state.snapshot.state, sequence == previousSequence {
                delay = min(2, delay * 1.5)
            } else {
                delay = pollInterval
            }
            previousState = state.snapshot.state
            try await Task.sleep(for: .seconds(delay))
        }
    }

    public func run(
        _ request: AgentTaskSubmission,
        onOutput: @escaping @Sendable (AgentTaskOutput) -> Void = { _ in }
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            _ = try await submit(request)
            return try await wait(request.id, onOutput: onOutput)
        } onCancel: {
            AgentTaskCancellationRelay.shared.cancel(request.id, client: client)
        }
    }

    public func runCommand(
        _ request: CLICommandRequest,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        do {
            let submission = AgentTaskSubmission(
                operation: AgentTaskOperation.command,
                title: "Running \(request.executableURL.lastPathComponent)",
                payload: try AgentPayload.encode(request))
            let data = try await run(submission)
            return try commandResult(
                data, onStandardOutputLine: onStandardOutputLine,
                onStandardErrorLine: onStandardErrorLine)
        } catch let failure as AgentTaskFailure {
            switch failure.snapshot.failureCode {
            case "commandExit":
                guard let result = failure.result else { throw failure }
                return try commandResult(
                    result, onStandardOutputLine: onStandardOutputLine,
                    onStandardErrorLine: onStandardErrorLine)
            case "timedOut": throw CLICommandRunnerError.timedOut
            case "outputLimitExceeded": throw CLICommandRunnerError.outputLimitExceeded
            case "launchFailed": throw CLICommandRunnerError.launchFailed
            case "streamFailed": throw CLICommandRunnerError.streamFailed
            default: throw failure
            }
        }
    }

    private func commandResult(
        _ data: Data, onStandardOutputLine: @Sendable (String) -> Void,
        onStandardErrorLine: @Sendable (String) -> Void
    ) throws -> CLICommandResult {
        let result = try AgentPayload.decode(CLICommandResult.self, from: data)
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            onStandardOutputLine(String(line))
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            onStandardErrorLine(String(line))
        }
        return result
    }
}

public enum AgentCommandRouting {
    private static let lock = NSLock()
    private static var enabled = false

    public static func enable() { lock.withLock { enabled = true } }
    public static var isEnabled: Bool { lock.withLock { enabled } }
}

private final class AgentTaskCancellationRelay: @unchecked Sendable {
    static let shared = AgentTaskCancellationRelay()
    private let lock = NSLock()
    private var retries: [UUID: Task<Void, Never>] = [:]

    func cancel(_ id: UUID, client: AgentClient) {
        lock.withLock {
            guard retries[id] == nil else { return }
            retries[id] = Task.detached(priority: .utility) { [weak self] in
                defer { self?.finish(id) }
                for attempt in 0..<30 {
                    do {
                        _ = try await AgentTaskClient(client: client).cancel(id)
                        return
                    } catch {
                        guard attempt < 29 else { return }
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
            }
        }
    }

    private func finish(_ id: UUID) { lock.withLock { retries[id] = nil } }

    deinit { for retry in retries.values { retry.cancel() } }
}
