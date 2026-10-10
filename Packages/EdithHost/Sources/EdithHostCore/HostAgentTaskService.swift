import CryptoKit
import EdithExtensionSupport
import Foundation

public struct HostAgentTaskLimits: Sendable {
    public let concurrency: Int
    public let queued: Int
    public let retained: Int
    public let payloadBytes: Int
    public let queuedPayloadBytes: Int
    public let resultBytes: Int
    public let retainedResultBytes: Int
    public let retention: TimeInterval

    public static var machineCap: Int {
        max(4, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    public let reservesInteractiveSlot: Bool

    public init(
        concurrency: Int = HostAgentTaskLimits.machineCap, queued: Int = 128, retained: Int = 100,
        payloadBytes: Int = 4 << 20, queuedPayloadBytes: Int = 16 << 20,
        resultBytes: Int = 8 << 20, retainedResultBytes: Int = 16 << 20,
        retention: TimeInterval = 86_400
    ) {
        self.concurrency = max(1, min(Self.machineCap, concurrency))
        self.reservesInteractiveSlot = self.concurrency > 4
        self.queued = max(1, queued)
        self.retained = max(1, retained)
        self.payloadBytes = max(1, payloadBytes)
        self.queuedPayloadBytes = max(1, queuedPayloadBytes)
        self.resultBytes = max(1, resultBytes)
        self.retainedResultBytes = max(1, retainedResultBytes)
        self.retention = max(0, retention)
    }
}

public struct HostAgentTaskContext: Sendable {
    private let output: HostAgentTaskOutputBuffer

    fileprivate init(output: HostAgentTaskOutputBuffer) { self.output = output }

    public func report(_ text: String, stream: HostAgentTaskOutputStream = .activity) {
        output.append(text, stream: stream)
    }
}

private final class HostAgentTaskOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private var lines: [HostAgentTaskOutput] = []

    func append(_ text: String, stream: HostAgentTaskOutputStream) {
        lock.withLock {
            sequence += 1
            lines.append(
                HostAgentTaskOutput(
                    sequence: sequence, stream: stream, text: String(text.prefix(1_000))))
            if lines.count > 128 { lines.removeFirst(lines.count - 128) }
        }
    }

    var values: [HostAgentTaskOutput] { lock.withLock { lines } }
}

private struct PersistedHostAgentTask: Codable {
    var fingerprint: String?
    var status: HostAgentTaskStatus
}

public actor HostAgentTaskService {
    public typealias Handler = @Sendable (Data, HostAgentTaskContext) async throws -> Data
    public typealias Publish = @Sendable ([HostAgentTaskSnapshot], UInt64) async -> Void
    public typealias RecordEvent = @Sendable (HostAgentCommandEvent) async -> Void

    private let journal: HostAgentJournal?
    private let limits: HostAgentTaskLimits
    private let publish: Publish
    private let record: RecordEvent
    private var entries: [UUID: PersistedHostAgentTask]
    private var handlers: [String: Handler] = [:]
    private var operationConcurrency: [String: Int] = [:]
    private var payloads: [UUID: Data] = [:]
    private var order: [UUID] = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var output: [UUID: HostAgentTaskOutputBuffer] = [:]
    private var publishedSequence: [UUID: Int] = [:]
    private var progressTask: Task<Void, Never>?
    private var snapshotRevision: UInt64 = 0
    private var publishNeeded = false
    private var publishTask: Task<Void, Never>?
    private var stopping = false

    public init(
        directory: URL?,
        limits: HostAgentTaskLimits = HostAgentTaskLimits(),
        publish: @escaping Publish = { _, _ in }, record: @escaping RecordEvent = { _ in }
    ) throws {
        self.journal = try directory.map { try HostAgentJournal(directory: $0) }
        self.limits = limits
        self.publish = publish
        self.record = record
        var restored: [UUID: PersistedHostAgentTask] = [:]
        if let journal {
            let files = try journal.files().filter { $0.pathExtension == "json" }
                .sorted {
                    let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    return (lhs ?? .distantPast) > (rhs ?? .distantPast)
                }
            var retainedBytes = 0
            for file in files {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                    let data = try? journal.read(
                        file.lastPathComponent, maximumBytes: limits.resultBytes * 2 + (1 << 20)),
                    var entry = try? HostAgentPayload.decode(
                        PersistedHostAgentTask.self, from: data),
                    entry.status.snapshot.id == id,
                    entry.status.output.count <= 128,
                    entry.status.output.allSatisfy({ $0.text.count <= 1000 })
                else { continue }
                let resultBytes = entry.status.result?.count ?? 0
                guard restored.count < limits.retained,
                    retainedBytes + resultBytes <= limits.retainedResultBytes,
                    !entry.status.snapshot.state.isTerminal
                        || Date().timeIntervalSince(
                            entry.status.snapshot.finishedAt ?? entry.status.snapshot.submittedAt)
                            <= limits.retention
                else {
                    try? journal.remove(file.lastPathComponent)
                    continue
                }
                retainedBytes += resultBytes
                if !entry.status.snapshot.state.isTerminal {
                    entry.status.snapshot.state = .interrupted
                    entry.status.snapshot.finishedAt = Date()
                    entry.status.snapshot.failure =
                        "The background agent restarted before this task finished."
                    entry.status.snapshot.failureCode = "interrupted"
                    try Self.write(entry, journal: journal)
                }
                restored[entry.status.snapshot.id] = entry
            }
        }
        entries = restored
    }

    deinit {
        for worker in workers.values { worker.cancel() }
        progressTask?.cancel()
    }

    public func shutdown() async {
        stopping = true
        order.removeAll()
        payloads.removeAll()
        for id in Array(entries.keys) {
            guard var entry = entries[id], !entry.status.snapshot.state.isTerminal else { continue }
            entry.status.snapshot.state = .interrupted
            entry.status.snapshot.finishedAt = Date()
            entry.status.snapshot.failure =
                "The background agent stopped before this task finished."
            entry.status.snapshot.failureCode = "interrupted"
            entries[id] = entry
            persistOrReport(entry)
        }
        let active = Array(workers.values)
        for worker in active { worker.cancel() }
        progressTask?.cancel()
        progressTask = nil
        for worker in active { await worker.value }
        scheduleSnapshotPublish()
        await publishTask?.value
    }

    public func register(
        operation: String, concurrency: Int? = nil, handler: @escaping Handler
    ) {
        guard !stopping else { return }
        handlers[operation] = handler
        operationConcurrency[operation] = concurrency.map { max(1, min(limits.concurrency, $0)) }
        startNext()
    }

    public func registerCommand() {
        register(operation: HostAgentTaskOperation.command) { payload, context in
            let request = try HostAgentPayload.decode(CLICommandRequest.self, from: payload)
            guard request.executableURL.isFileURL,
                request.executableURL.path.hasPrefix("/"),
                request.currentDirectoryURL.map({ $0.isFileURL && $0.path.hasPrefix("/") }) ?? true,
                request.timeout.map({ $0.isFinite && $0 > 0 }) ?? true,
                request.maximumOutputBytes.map({ $0 > 0 }) ?? true
            else { throw HostAgentCommandError(.refused, "The command request is invalid.") }
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
            let encoded = try HostAgentPayload.encode(result)
            guard result.terminationStatus == 0 else {
                throw HostAgentTaskExecutionError(
                    code: "commandExit",
                    message: "Command exited with status \(result.terminationStatus).",
                    result: encoded)
            }
            return encoded
        }
    }

    public func submit(_ request: HostAgentTaskSubmission) throws -> HostAgentTaskSnapshot {
        guard !stopping else {
            throw HostAgentCommandError(.unavailable, "The agent is shutting down.")
        }
        prune()
        guard request.payload.count <= limits.payloadBytes else {
            throw HostAgentCommandError(.refused, "The background task request is too large.")
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
                throw HostAgentCommandError(
                    .refused, "This task identifier was already used for a different request.")
            }
            return existing.status.snapshot
        }
        guard handlers[request.operation] != nil else {
            throw HostAgentCommandError(
                .unknownOperation, "No background task handles \(request.operation).")
        }
        guard order.count < limits.queued,
            payloads.values.reduce(0, { $0 + $1.count }) + request.payload.count
                <= limits.queuedPayloadBytes
        else {
            throw HostAgentCommandError(
                .refused, "The background task queue is full. Try again when a task finishes.")
        }
        let snapshot = HostAgentTaskSnapshot(
            id: request.id, operation: request.operation, title: String(request.title.prefix(160)))
        let entry = PersistedHostAgentTask(
            fingerprint: fingerprint, status: HostAgentTaskStatus(snapshot: snapshot))
        try persist(entry)
        entries[request.id] = entry
        payloads[request.id] = request.payload
        order.append(request.id)
        notify(snapshot, name: "task.queued")
        startNext()
        return entries[request.id]!.status.snapshot
    }

    public func status(_ id: UUID) throws -> HostAgentTaskStatus {
        guard var entry = entries[id] else {
            throw HostAgentCommandError(.failed, "The background task is no longer retained.")
        }
        if let lines = output[id]?.values {
            entry.status.output = lines
            entry.status.snapshot.lastActivity = lines.last?.text
        }
        return entry.status
    }

    public func snapshots() -> [HostAgentTaskSnapshot] {
        entries.keys.compactMap { try? status($0).snapshot }
            .sorted {
                if $0.submittedAt == $1.submittedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.submittedAt > $1.submittedAt
            }
    }

    public func cancel(_ id: UUID) throws -> HostAgentTaskSnapshot {
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
            notify(entry.status.snapshot, name: "task.\(entry.status.snapshot.state.rawValue)")
            startNext()
            return entry.status.snapshot
        }
        prune()
        let snapshot = HostAgentTaskSnapshot(
            id: id, operation: "pending", title: "Cancelled task", state: .cancelled,
            finishedAt: Date())
        let entry = PersistedHostAgentTask(
            fingerprint: nil, status: HostAgentTaskStatus(snapshot: snapshot))
        try persist(entry)
        entries[id] = entry
        return snapshot
    }

    private func startNext() {
        guard !stopping else { return }
        while workers.count < limits.concurrency, !order.isEmpty {
            guard
                let index = order.firstIndex(where: { id in
                    guard let operation = entries[id]?.status.snapshot.operation else {
                        return true
                    }
                    if let maximum = operationConcurrency[operation] {
                        let active = workers.keys.lazy.filter {
                            self.entries[$0]?.status.snapshot.operation == operation
                        }.count
                        if active >= maximum { return false }
                    }
                    if limits.reservesInteractiveSlot, workers.count >= limits.concurrency - 1 {
                        let same = workers.keys.contains {
                            self.entries[$0]?.status.snapshot.operation == operation
                        }
                        if same { return false }
                    }
                    return true
                })
            else { break }
            let id = order.remove(at: index)
            guard var entry = entries[id], let payload = payloads.removeValue(forKey: id),
                let handler = handlers[entry.status.snapshot.operation]
            else { continue }
            entry.status.snapshot.state = .running
            entry.status.snapshot.startedAt = Date()
            entries[id] = entry
            persistOrReport(entry)
            let buffer = HostAgentTaskOutputBuffer()
            output[id] = buffer
            let context = HostAgentTaskContext(output: buffer)
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
        if entry.status.snapshot.state != .interrupted {
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
                if !wasCancelled, let failure = error as? HostAgentTaskExecutionError,
                    let result = failure.result, result.count <= limits.resultBytes
                {
                    entry.status.result = result
                }
            }
        }
        if entry.status.snapshot.state == .cancelled {
            entry.status.snapshot.failure = "Cancelled by request."
            entry.status.snapshot.failureCode = "cancelled"
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
        if changed { scheduleSnapshotPublish() }
    }

    private func scheduleSnapshotPublish() {
        publishNeeded = true
        guard publishTask == nil else { return }
        publishTask = Task { await self.drainSnapshotPublish() }
    }

    private func drainSnapshotPublish() async {
        while publishNeeded {
            publishNeeded = false
            snapshotRevision &+= 1
            await publish(snapshots(), snapshotRevision)
        }
        publishTask = nil
        if publishNeeded { scheduleSnapshotPublish() }
    }

    private func notify(_ snapshot: HostAgentTaskSnapshot, name: String) {
        let event = HostAgentCommandEvent(
            level: snapshot.state == .failed ? .error : .info,
            category: "task", name: name, message: "\(snapshot.title): \(snapshot.state.rawValue)",
            duration: snapshot.finishedAt.flatMap { finished in
                snapshot.startedAt.map { finished.timeIntervalSince($0) }
            }, taskID: snapshot.id)
        Task { [weak self, record] in
            await record(event)
            await self?.scheduleSnapshotPublish()
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
                if let journal { try? journal.remove(Self.fileName(snapshot.id)) }
            }
        }
    }

    private func persist(_ entry: PersistedHostAgentTask) throws {
        if let journal { try Self.write(entry, journal: journal) }
    }

    private func persistOrReport(_ entry: PersistedHostAgentTask) {
        do { try persist(entry) } catch {
            let event = HostAgentCommandEvent(
                level: .error, category: "task", name: "task.persistence.failed",
                message: error.localizedDescription)
            Task { [record] in await record(event) }
        }
    }

    private static func fileName(_ id: UUID) -> String { "\(id.uuidString).json" }

    private static func write(_ entry: PersistedHostAgentTask, journal: HostAgentJournal) throws {
        try journal.write(
            HostAgentPayload.encode(entry), name: fileName(entry.status.snapshot.id),
            maximumBytes: (17 << 20))
    }

    private static func fingerprint(_ request: HostAgentTaskSubmission) -> String {
        var digest = SHA256()
        digest.update(data: Data(request.operation.utf8))
        digest.update(data: Data([0]))
        digest.update(data: request.payload)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func failureCode(_ error: Error) -> String? {
        if let failure = error as? HostAgentTaskExecutionError { return failure.code }
        guard let command = error as? CLICommandRunnerError else { return nil }
        return switch command {
        case .launchFailed: "launchFailed"
        case .timedOut: "timedOut"
        case .outputLimitExceeded: "outputLimitExceeded"
        case .streamFailed: "streamFailed"
        }
    }
}
