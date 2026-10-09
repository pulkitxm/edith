import Foundation

public enum MusicDownloadOperation {
    public static let snapshot = "download.worker.snapshot"
    public static let mutate = "download.worker.mutate"
    public static let estimate = "download.worker.estimate"
    public static let internalOperations = [snapshot, mutate]
}

public enum MusicDownloadMutation: Codable, Sendable {
    case enqueue(
        urls: [URL], prefix: String, kind: DownloadKind, outputDirectory: URL,
        browser: DownloadBrowser? = nil)
    case retry(id: UUID?, all: Bool)
    case cancel(id: UUID?, includeQueued: Bool, reason: String)
    case remove(id: UUID)
    case clear(includeActive: Bool)
}

public struct MusicDownloadMutationResult: Codable, Sendable {
    public let changed: Int
    public let records: [DownloadRecord]
    public let added: [DownloadRecord]

    public init(changed: Int, records: [DownloadRecord], added: [DownloadRecord] = []) {
        self.changed = changed
        self.records = records
        self.added = added
    }

    public var mutation: DownloadMutationResult {
        DownloadMutationResult(changed: changed, records: records)
    }
}

public struct DownloadWorkerSnapshot: Codable, Sendable {
    public let readAt: Date
    public let generation: UUID
    public let revision: Int
    public let queued: Int
    public let running: Int
    public let finished: Int
    public let failed: Int
    public let records: [DownloadRecord]
    public let logs: [String: String]
    public let enabled: Bool
    public let problem: String?
    public let executable: URL?

    public init(
        records: [DownloadRecord], logs: [String: String], enabled: Bool, running: Bool,
        generation: UUID, revision: Int, problem: String? = nil, executable: URL? = nil
    ) {
        self.problem = problem
        self.executable = executable
        self.generation = generation
        self.revision = revision
        self.readAt = Date()
        self.records = records
        self.logs = logs
        self.enabled = enabled
        self.queued = records.count { $0.status == .queued }
        self.running = running ? 1 : 0
        self.finished = records.count { if case .done = $0.status { true } else { false } }
        self.failed = records.count { $0.canRetry }
    }
}

public struct MusicDownloadClient: Sendable {
    public let worker: DownloadWorker
    public init(worker: DownloadWorker = .shared) { self.worker = worker }
    public func snapshot() async throws -> DownloadWorkerSnapshot { await worker.snapshot() }
    public func mutateAsync(_ request: MusicDownloadMutation) async throws
        -> MusicDownloadMutationResult
    {
        try await worker.mutate(request)
    }
    public func estimate(_ url: URL) async throws -> DownloadEstimate? {
        try await worker.estimate(url)
    }
    public func values() async throws -> AsyncStream<DownloadWorkerSnapshot> {
        try await worker.values()
    }
}

struct MusicDownloadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
