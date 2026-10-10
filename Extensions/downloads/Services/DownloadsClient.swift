import EdithExtensionSupport
import Foundation

public enum DownloadsOperation {
    public static let snapshot = "download.worker.snapshot"
    public static let mutate = "download.worker.mutate"
    public static let estimate = "download.worker.estimate"
    public static let internalOperations = [snapshot, mutate]
}

public enum DownloadsMutation: Codable, Sendable {
    case enqueue(
        urls: [URL], prefix: String, kind: DownloadKind, outputDirectory: URL,
        browser: DownloadBrowser? = nil)
    case retry(id: UUID?, all: Bool)
    case cancel(id: UUID?, includeQueued: Bool, reason: String)
    case remove(id: UUID)
    case clear(includeActive: Bool)
}

public struct DownloadsMutationResult: Codable, Sendable {
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

public struct DownloadsClient: Sendable {
    private let read: @Sendable () async throws -> DownloadWorkerSnapshot
    private let change: @Sendable (DownloadsMutation) async throws -> DownloadsMutationResult
    private let measure: @Sendable (URL) async throws -> DownloadEstimate?
    private let observe: @Sendable () async throws -> AsyncStream<DownloadWorkerSnapshot>

    public init(worker: DownloadWorker = .shared) {
        read = { await worker.snapshot() }
        change = { try await worker.mutate($0) }
        measure = { try await worker.estimate($0) }
        observe = { try await worker.values() }
    }

    @MainActor init(client: ExtensionEngineClient) {
        read = {
            let data = try await client.invoke("downloads.snapshot")
            return try JSONDecoder().decode(DownloadWorkerSnapshot.self, from: data)
        }
        change = { request in
            let data = try await client.invoke(
                "downloads.mutate", payload: JSONEncoder().encode(request))
            return try JSONDecoder().decode(DownloadsMutationResult.self, from: data)
        }
        measure = { url in
            let data = try await client.invoke(
                "downloads.estimate", payload: JSONEncoder().encode(url))
            return try JSONDecoder().decode(DownloadEstimate?.self, from: data)
        }
        let read = read
        observe = {
            AsyncStream { continuation in
                let task = Task {
                    do {
                        while !Task.isCancelled {
                            continuation.yield(try await read())
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch {}
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    public func snapshot() async throws -> DownloadWorkerSnapshot { try await read() }
    public func mutateAsync(_ request: DownloadsMutation) async throws -> DownloadsMutationResult {
        try await change(request)
    }
    public func estimate(_ url: URL) async throws -> DownloadEstimate? { try await measure(url) }
    public func values() async throws -> AsyncStream<DownloadWorkerSnapshot> { try await observe() }
}

struct DownloadsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
