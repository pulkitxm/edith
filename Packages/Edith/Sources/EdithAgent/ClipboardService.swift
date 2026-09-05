import EdithKit
import Foundation

public actor ClipboardService {
    public static let maximumRequests = 16
    public static let maximumQueuedBytes = 48 << 20
    private let archive: ClipboardArchive
    private let defaults: UserDefaults
    private let changed: @Sendable () -> Void
    private var workers: [UUID: Task<Data, Error>] = [:]
    private var tail: Task<Void, Never>?
    private var tailID: UUID?
    private var queuedBytes = 0
    private var stopped = false

    public init(
        archive: ClipboardArchive = .init(), defaults: UserDefaults = SharedDefaults.store,
        changed: @escaping @Sendable () -> Void = { IPC.post(IPC.Name.clipboardChanged) }
    ) {
        self.archive = archive
        self.defaults = defaults
        self.changed = changed
    }

    var activeRequests: Int { workers.count }

    public func register(on runtime: AgentRuntime) async {
        for operation in AgentClipboardOperation.internalOperations {
            await runtime.register(operation: operation) { payload in
                try await self.perform(operation: operation, payload: payload)
            }
        }
        await runtime.registerShutdown(id: "clipboard") { await self.stop() }
    }

    public func perform(operation: String, payload: Data) async throws -> Data {
        guard !stopped else { throw AgentError(.unavailable, "Clipboard storage is stopping.") }
        let limit = operation == AgentClipboardOperation.capture ? (23 << 20) : (1 << 20)
        guard payload.count <= limit else {
            throw AgentError(.refused, "The clipboard payload is too large.")
        }
        guard workers.count < Self.maximumRequests,
            queuedBytes + payload.count <= Self.maximumQueuedBytes
        else { throw AgentError(.unavailable, "The clipboard request queue is full.") }
        let maxItems =
            defaults.object(forKey: AppStorageKeys.Clipboard.maxItems) as? Int
            ?? ClipboardIndex.defaultMaxItems
        let maxBytes =
            defaults.object(forKey: AppStorageKeys.Clipboard.maxItemBytes) as? Int
            ?? ClipboardIndex.defaultMaxItemBytes
        let age = defaults.object(forKey: AppStorageKeys.Clipboard.maxAgeDays) as? Int ?? 0
        let maxAge = age > 0 ? Double(age) * 86400 : nil
        let archive = archive
        let changed = changed
        let predecessor = tail
        let id = UUID()
        let worker = Task.detached(priority: .utility) {
            await predecessor?.value
            try Task.checkCancellation()
            switch operation {
            case AgentClipboardOperation.capture:
                let request = try AgentPayload.decode(ClipboardCapture.self, from: payload)
                let result = try archive.capture(
                    request, maxItems: maxItems, maxBytes: maxBytes, maxAge: maxAge)
                if result.changed > 0 { changed() }
                return try AgentPayload.encode(result)
            case AgentClipboardOperation.mutate:
                let request = try AgentPayload.decode(ClipboardMutation.self, from: payload)
                let result = try archive.mutate(request)
                if result.changed > 0 { changed() }
                return try AgentPayload.encode(result)
            case AgentClipboardOperation.snapshot:
                let request = try AgentPayload.decode(ClipboardSnapshotRequest.self, from: payload)
                return try AgentPayload.encode(archive.snapshot(request))
            case AgentClipboardOperation.blob:
                let id = try AgentPayload.decode(String.self, from: payload)
                return try AgentPayload.encode(archive.payload(id: id))
            case AgentClipboardOperation.stats:
                return try AgentPayload.encode(archive.stats())
            default: throw AgentError(.unknownOperation, "Unknown clipboard operation.")
            }
        }
        workers[id] = worker
        queuedBytes += payload.count
        tail = Task { _ = try? await worker.value }
        tailID = id
        defer {
            workers[id] = nil
            queuedBytes -= payload.count
            if tailID == id { tail = nil; tailID = nil }
        }
        return try await worker.value
    }

    public func stop() async {
        stopped = true
        let active = Array(workers.values)
        for worker in active { worker.cancel() }
        for worker in active { _ = try? await worker.value }
        await tail?.value
        tail = nil
        tailID = nil
    }

    deinit {
        tail?.cancel()
        for worker in workers.values { worker.cancel() }
    }
}
