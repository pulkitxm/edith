import CryptoKit
import EdithKit
import Foundation

public struct AgentTaskLimits: Sendable {
    public let concurrency: Int
    public let queued: Int
    public let retained: Int
    public let payloadBytes: Int
    public let queuedPayloadBytes: Int
    public let resultBytes: Int
    public let retainedResultBytes: Int
    public let retention: TimeInterval

    public init(
        concurrency: Int = 4, queued: Int = 128, retained: Int = 100,
        payloadBytes: Int = 4 << 20, queuedPayloadBytes: Int = 16 << 20,
        resultBytes: Int = 8 << 20, retainedResultBytes: Int = 16 << 20,
        retention: TimeInterval = 86_400
    ) {
        self.concurrency = max(1, min(4, concurrency))
        self.queued = max(1, queued)
        self.retained = max(1, retained)
        self.payloadBytes = max(1, payloadBytes)
        self.queuedPayloadBytes = max(1, queuedPayloadBytes)
        self.resultBytes = max(1, resultBytes)
        self.retainedResultBytes = max(1, retainedResultBytes)
        self.retention = max(0, retention)
    }
}

public struct AgentTaskContext: Sendable {
    private let output: AgentTaskOutputBuffer

    fileprivate init(output: AgentTaskOutputBuffer) { self.output = output }

    public func report(_ text: String, stream: AgentTaskOutputStream = .activity) {
        output.append(text, stream: stream)
    }
}

private final class AgentTaskOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private var lines: [AgentTaskOutput] = []

    func append(_ text: String, stream: AgentTaskOutputStream) {
        lock.withLock {
            sequence += 1
            lines.append(
                AgentTaskOutput(
                    sequence: sequence, stream: stream, text: String(text.prefix(1_000))))
            if lines.count > 128 { lines.removeFirst(lines.count - 128) }
        }
    }

    var values: [AgentTaskOutput] { lock.withLock { lines } }
}

private struct PersistedAgentTask: Codable {
    var fingerprint: String?
    var status: AgentTaskStatus
}

public actor AgentTaskService {
    public typealias Handler = @Sendable (Data, AgentTaskContext) async throws -> Data
    public typealias Publish = @Sendable ([AgentTaskSnapshot]) async -> Void
    public typealias RecordEvent = @Sendable (AgentEvent) async -> Void

    private let directory: URL?
    private let limits: AgentTaskLimits
    private let publish: Publish
    private let record: RecordEvent
    private var entries: [UUID: PersistedAgentTask]
    private var handlers: [String: Handler] = [:]
    private var payloads: [UUID: Data] = [:]
    private var order: [UUID] = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var output: [UUID: AgentTaskOutputBuffer] = [:]
    private var publishedSequence: [UUID: Int] = [:]
    private var progressTask: Task<Void, Never>?

    public init(
        directory: URL? = AppData.supportDir.appendingPathComponent("Tasks", isDirectory: true),
        limits: AgentTaskLimits = AgentTaskLimits(),
        publish: @escaping Publish = { _ in }, record: @escaping RecordEvent = { _ in }
    ) throws {
        self.directory = directory
        self.limits = limits
        self.publish = publish
        self.record = record
        var restored: [UUID: PersistedAgentTask] = [:]
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            .filter { $0.pathExtension == "json" }
            .sorted {
                let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return (lhs ?? .distantPast) > (rhs ?? .distantPast)
            }
            var retainedBytes = 0
            for file in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= limits.resultBytes * 2 + (1 << 20),
                    let data = try? Data(contentsOf: file),
                    var entry = try? AgentPayload.decode(PersistedAgentTask.self, from: data)
                else { continue }
                let resultBytes = entry.status.result?.count ?? 0
                guard restored.count < limits.retained,
                    retainedBytes + resultBytes <= limits.retainedResultBytes,
                    !entry.status.snapshot.state.isTerminal
                        || Date().timeIntervalSince(
                            entry.status.snapshot.finishedAt ?? entry.status.snapshot.submittedAt)
                            <= limits.retention
                else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                retainedBytes += resultBytes
                if !entry.status.snapshot.state.isTerminal {
                    entry.status.snapshot.state = .interrupted
                    entry.status.snapshot.finishedAt = Date()
                    entry.status.snapshot.failure =
                        "The background agent restarted before this task finished."
                    entry.status.snapshot.failureCode = "interrupted"
                    try Self.write(entry, directory: directory)
                }
                restored[entry.status.snapshot.id] = entry
            }
        }
        entries = restored
    }

    public func register(operation: String, handler: @escaping Handler) {
        handlers[operation] = handler
    }

    public func registerCommand() {
        register(operation: AgentTaskOperation.command) { payload, context in
            let request = try AgentPayload.decode(CLICommandRequest.self, from: payload)
            guard request.executableURL.isFileURL,
                request.executableURL.path.hasPrefix("/"),
                request.timeout.map({ $0.isFinite && $0 > 0 }) ?? true,
                request.maximumOutputBytes.map({ $0 > 0 }) ?? true
            else { throw AgentError(.refused, "The command request is invalid.") }
            let bounded = CLICommandRequest(
                executableURL: request.executableURL, arguments: request.arguments,
                environment: request.environment, currentDirectoryURL: request.currentDirectoryURL,
                timeout: min(request.timeout ?? 1_800, 7_200),
                maximumOutputBytes: min(request.maximumOutputBytes ?? (2 << 20), 2 << 20),
                standardInputData: request.standardInputData,
                discardsStandardError: request.discardsStandardError,
                terminatesProcessGroup: true)
            let result = try await CLICommandRunner.runLocalSeparated(
                bounded, streamsWhileRunning: true,
                onStandardOutputLine: { context.report($0, stream: .standardOutput) },
                onStandardErrorLine: { context.report($0, stream: .standardError) })
            return try AgentPayload.encode(result)
        }
    }

    public func submit(_ request: AgentTaskSubmission) throws -> AgentTaskSnapshot {
        prune()
        guard request.payload.count <= limits.payloadBytes else {
            throw AgentError(.refused, "The background task request is too large.")
        }
        let fingerprint = Self.fingerprint(request)
        if var existing = entries[request.id] {
            if existing.fingerprint == nil, existing.status.snapshot.state == .cancelled {
                existing.fingerprint = fingerprint
                existing.status.snapshot.operation = request.operation
                existing.status.snapshot.title = String(request.title.prefix(160))
                try persist(existing)
                entries[request.id] = existing
                return existing.status.snapshot
            }
            guard existing.fingerprint == fingerprint else {
                throw AgentError(
                    .refused, "This task identifier was already used for a different request.")
            }
            return existing.status.snapshot
        }
        guard handlers[request.operation] != nil else {
            throw AgentError(.unknownOperation, "No background task handles \(request.operation).")
        }
        guard order.count < limits.queued,
            payloads.values.reduce(0, { $0 + $1.count }) + request.payload.count
                <= limits.queuedPayloadBytes
        else {
            throw AgentError(
                .refused, "The background task queue is full. Try again when a task finishes.")
        }
        let snapshot = AgentTaskSnapshot(
            id: request.id, operation: request.operation, title: String(request.title.prefix(160)))
        let entry = PersistedAgentTask(
            fingerprint: fingerprint, status: AgentTaskStatus(snapshot: snapshot))
        try persist(entry)
        entries[request.id] = entry
        payloads[request.id] = request.payload
        order.append(request.id)
        notify(snapshot, name: "task.queued")
        startNext()
        return entries[request.id]!.status.snapshot
    }

    public func status(_ id: UUID) throws -> AgentTaskStatus {
        guard var entry = entries[id] else {
            throw AgentError(.failed, "The background task is no longer retained.")
        }
        if let lines = output[id]?.values {
            entry.status.output = lines
            entry.status.snapshot.lastActivity = lines.last?.text
        }
        return entry.status
    }

    public func snapshots() -> [AgentTaskSnapshot] {
        entries.keys.compactMap { try? status($0).snapshot }
            .sorted {
                if $0.submittedAt == $1.submittedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.submittedAt > $1.submittedAt
            }
    }

    public func cancel(_ id: UUID) throws -> AgentTaskSnapshot {
        if var entry = entries[id] {
            guard !entry.status.snapshot.state.isTerminal else { return entry.status.snapshot }
            if workers[id] != nil {
                entry.status.snapshot.state = .cancelling
            } else {
                entry.status.snapshot.state = .cancelled
                entry.status.snapshot.finishedAt = Date()
                payloads[id] = nil
                order.removeAll { $0 == id }
            }
            entries[id] = entry
            workers[id]?.cancel()
            persistOrReport(entry)
            notify(entry.status.snapshot, name: "task.cancelled")
            startNext()
            return entry.status.snapshot
        }
        prune()
        let snapshot = AgentTaskSnapshot(
            id: id, operation: "pending", title: "Cancelled task", state: .cancelled,
            finishedAt: Date())
        let entry = PersistedAgentTask(
            fingerprint: nil, status: AgentTaskStatus(snapshot: snapshot))
        try persist(entry)
        entries[id] = entry
        return snapshot
    }

    private func startNext() {
        while workers.count < limits.concurrency, !order.isEmpty {
            let id = order.removeFirst()
            guard var entry = entries[id], let payload = payloads.removeValue(forKey: id),
                let handler = handlers[entry.status.snapshot.operation]
            else { continue }
            entry.status.snapshot.state = .running
            entry.status.snapshot.startedAt = Date()
            entries[id] = entry
            persistOrReport(entry)
            let buffer = AgentTaskOutputBuffer()
            output[id] = buffer
            let context = AgentTaskContext(output: buffer)
            workers[id] = Task.detached(priority: .utility) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let result = try await handler(payload, context)
                    await self?.finish(id, result: .success(result))
                } catch {
                    await self?.finish(id, result: .failure(error))
                }
            }
            notify(entry.status.snapshot, name: "task.started")
        }
        startProgressPublishing()
    }

    private func finish(_ id: UUID, result: Result<Data, Error>) {
        guard var entry = entries[id] else { return }
        let wasCancelled = entry.status.snapshot.state == .cancelling
        workers[id] = nil
        entry.status.output = output.removeValue(forKey: id)?.values ?? []
        entry.status.snapshot.lastActivity = entry.status.output.last?.text
        publishedSequence[id] = nil
        entry.status.snapshot.finishedAt = Date()
        switch result {
        case .success(let data) where !wasCancelled && data.count <= limits.resultBytes:
            entry.status.snapshot.state = .succeeded
            entry.status.result = data
        case .success where wasCancelled:
            entry.status.snapshot.state = .cancelled
        case .success:
            entry.status.snapshot.state = .failed
            entry.status.snapshot.failure =
                "The background task result exceeded its retained output limit."
            entry.status.snapshot.failureCode = "outputLimitExceeded"
        case .failure(let error):
            entry.status.snapshot.state =
                wasCancelled || error is CancellationError ? .cancelled : .failed
            entry.status.snapshot.failure = String(error.localizedDescription.prefix(2_000))
            entry.status.snapshot.failureCode = Self.failureCode(error)
        }
        entries[id] = entry
        persistOrReport(entry)
        notify(entry.status.snapshot, name: "task.\(entry.status.snapshot.state.rawValue)")
        prune()
        startNext()
        if workers.isEmpty {
            progressTask?.cancel()
            progressTask = nil
        }
    }

    private func startProgressPublishing() {
        guard !workers.isEmpty, progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                await publishProgress()
            }
        }
    }

    private func publishProgress() async {
        var changed = false
        for (id, buffer) in output {
            let sequence = buffer.values.last?.sequence ?? 0
            if sequence != publishedSequence[id] {
                publishedSequence[id] = sequence
                changed = true
            }
        }
        if changed { await publish(snapshots()) }
    }

    private func notify(_ snapshot: AgentTaskSnapshot, name: String) {
        let event = AgentEvent(
            level: snapshot.state == .failed ? .error : .info,
            category: "task", name: name, message: "\(snapshot.title): \(snapshot.state.rawValue)",
            duration: snapshot.finishedAt.flatMap { finished in
                snapshot.startedAt.map { finished.timeIntervalSince($0) }
            })
        Task { [weak self, record] in
            await record(event)
            guard let self else { return }
            await publish(snapshots())
        }
    }

    private func prune(now: Date = Date()) {
        let finished = entries.values.filter { $0.status.snapshot.state.isTerminal }
            .sorted {
                ($0.status.snapshot.finishedAt ?? .distantPast)
                    > ($1.status.snapshot.finishedAt ?? .distantPast)
            }
        var retainedBytes = 0
        for (index, entry) in finished.enumerated() {
            let snapshot = entry.status.snapshot
            retainedBytes += entry.status.result?.count ?? 0
            if index >= limits.retained || retainedBytes > limits.retainedResultBytes
                || now.timeIntervalSince(snapshot.finishedAt ?? snapshot.submittedAt)
                    > limits.retention
            {
                entries[snapshot.id] = nil
                if let directory {
                    try? FileManager.default.removeItem(
                        at: Self.file(snapshot.id, directory: directory))
                }
            }
        }
    }

    private func persist(_ entry: PersistedAgentTask) throws {
        if let directory { try Self.write(entry, directory: directory) }
    }

    private func persistOrReport(_ entry: PersistedAgentTask) {
        do { try persist(entry) } catch {
            let event = AgentEvent(
                level: .error, category: "task", name: "task.persistence.failed",
                message: error.localizedDescription)
            Task { [record] in await record(event) }
        }
    }

    private static func file(_ id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func write(_ entry: PersistedAgentTask, directory: URL) throws {
        let file = file(entry.status.snapshot.id, directory: directory)
        try AgentPayload.encode(entry).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func fingerprint(_ request: AgentTaskSubmission) -> String {
        var digest = SHA256()
        digest.update(data: Data(request.operation.utf8))
        digest.update(data: Data([0]))
        digest.update(data: request.payload)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func failureCode(_ error: Error) -> String? {
        guard let command = error as? CLICommandRunnerError else { return nil }
        return switch command {
        case .launchFailed: "launchFailed"
        case .timedOut: "timedOut"
        case .outputLimitExceeded: "outputLimitExceeded"
        case .streamFailed: "streamFailed"
        }
    }
}
