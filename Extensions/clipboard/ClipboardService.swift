import EdithExtensionSupport
import Foundation

public actor ClipboardService {
    public static let maximumRequests = 16
    public static let maximumQueuedBytes = 48 << 20
    private let archive: ClipboardArchive
    private let thumbnails: ClipboardThumbnailService
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
        thumbnails = ClipboardThumbnailService(archive: archive)
        self.defaults = defaults
        self.changed = changed
    }

    var activeRequests: Int { workers.count }

    public func perform(operation: String, payload: Data) async throws -> Data {
        guard !stopped else {
            throw ClipboardServiceError(.unavailable, "Clipboard storage is stopping.")
        }
        if operation == ClipboardServiceOperation.thumbnail {
            guard payload.count <= 4096 else {
                throw ClipboardServiceError(.refused, "The clipboard preview request is too large.")
            }
            return try await ClipboardMessage.encode(
                thumbnails.read(
                    ClipboardMessage.decode(ClipboardThumbnailRequest.self, from: payload)))
        }
        if operation == ClipboardServiceOperation.cancelThumbnail {
            guard payload.count <= 128 else {
                throw ClipboardServiceError(
                    .refused, "The clipboard preview cancellation is invalid.")
            }
            await thumbnails.cancel(try ClipboardMessage.decode(UUID.self, from: payload))
            return Data()
        }
        let limit = operation == ClipboardServiceOperation.capture ? (23 << 20) : (1 << 20)
        guard payload.count <= limit else {
            throw ClipboardServiceError(.refused, "The clipboard payload is too large.")
        }
        guard workers.count < Self.maximumRequests,
            queuedBytes + payload.count <= Self.maximumQueuedBytes
        else { throw ClipboardServiceError(.unavailable, "The clipboard request queue is full.") }
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
        let writes =
            operation == ClipboardServiceOperation.capture
            || operation == ClipboardServiceOperation.mutate
        let predecessor = writes ? tail : nil
        let id = UUID()
        let worker = Task.detached(priority: .utility) {
            if writes { await predecessor?.value }
            try Task.checkCancellation()
            switch operation {
            case ClipboardServiceOperation.capture:
                let request = try ClipboardMessage.decode(ClipboardCapture.self, from: payload)
                let result = try archive.capture(
                    ClipboardPreviewPreparation.prepare(request), maxItems: maxItems,
                    maxBytes: maxBytes, maxAge: maxAge)
                if result.changed > 0 { changed() }
                return try ClipboardMessage.encode(result)
            case ClipboardServiceOperation.mutate:
                let request = try ClipboardMessage.decode(ClipboardMutation.self, from: payload)
                let result = try archive.mutate(request)
                if result.changed > 0 { changed() }
                return try ClipboardMessage.encode(result)
            case ClipboardServiceOperation.snapshot:
                let request = try ClipboardMessage.decode(
                    ClipboardSnapshotRequest.self, from: payload)
                return try ClipboardMessage.encode(archive.snapshot(request))
            case ClipboardServiceOperation.blob:
                let id = try ClipboardMessage.decode(String.self, from: payload)
                return try ClipboardMessage.encode(archive.payload(id: id))
            case ClipboardServiceOperation.copy:
                let request = try ClipboardMessage.decode(ClipboardCopyRequest.self, from: payload)
                let stored = try archive.payload(id: request.id)
                return try ClipboardMessage.encode(
                    ClipboardPreviewPreparation.copy(stored, plainTextOnly: request.plainTextOnly))
            case ClipboardServiceOperation.inspect:
                return try ClipboardMessage.encode(archive.inspect())
            case ClipboardServiceOperation.stats:
                return try ClipboardMessage.encode(archive.stats())
            default: throw ClipboardServiceError(.unknownOperation, "Unknown clipboard operation.")
            }
        }
        workers[id] = worker
        queuedBytes += payload.count
        if writes {
            tail = Task { _ = try? await worker.value }
            tailID = id
        }
        defer {
            workers[id] = nil
            queuedBytes -= payload.count
            if writes, tailID == id { tail = nil; tailID = nil }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func stop() async {
        stopped = true
        await thumbnails.stop()
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
