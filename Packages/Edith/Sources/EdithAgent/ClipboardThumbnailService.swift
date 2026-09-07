import Darwin
import EdithKit
import Foundation

public actor ClipboardThumbnailService {
    public typealias Loader = @Sendable (ClipboardStoredPayload) async throws -> Data?
    private struct Flight {
        let request: ClipboardThumbnailRequest
        let continuation: CheckedContinuation<ClipboardThumbnailSnapshot, Error>
    }
    private struct Cached {
        let snapshot: ClipboardThumbnailSnapshot
        let expires: Date
    }

    private let archive: ClipboardArchive
    private let loader: Loader
    private let concurrency: Int
    private let capacity: Int
    private let timeout: TimeInterval
    private var cache: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private var flights: [UUID: Flight] = [:]
    private var queue: [UUID] = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var cancelled: [UUID: Date] = [:]
    private var stopped = false

    public init(
        archive: ClipboardArchive, concurrency: Int = 2, capacity: Int = 32,
        timeout: TimeInterval = 10,
        loader: @escaping Loader = { try await ClipboardThumbnailRenderer.render($0) }
    ) {
        self.archive = archive
        self.loader = loader
        self.concurrency = max(1, concurrency)
        self.capacity = max(1, capacity)
        self.timeout = max(0.01, timeout)
    }

    var activity: (active: Int, pending: Int, cachedBytes: Int) {
        (workers.count, flights.count, cacheBytes)
    }

    public func read(_ request: ClipboardThumbnailRequest) async throws
        -> ClipboardThumbnailSnapshot
    {
        guard !stopped else { throw AgentError(.unavailable, "Clipboard previews are stopping.") }
        cancelled = cancelled.filter { $0.value > Date().addingTimeInterval(-30) }
        if cancelled.removeValue(forKey: request.id) != nil { throw CancellationError() }
        guard request.entryID.utf8.count <= 128, flights[request.id] == nil,
            workers[request.id] == nil,
            flights.count < capacity
        else { throw AgentError(.refused, "The clipboard preview queue is full.") }
        return try await withCheckedThrowingContinuation { continuation in
            flights[request.id] = Flight(request: request, continuation: continuation)
            queue.append(request.id)
            let timeout = timeout
            deadlines[request.id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                await self?.expire(request.id)
            }
            startNext()
        }
    }

    public func cancel(_ id: UUID) {
        guard flights[id] != nil else {
            if cancelled.count >= 64, let oldest = cancelled.min(by: { $0.value < $1.value }) {
                cancelled[oldest.key] = nil
            }
            cancelled[id] = Date()
            return
        }
        workers[id]?.cancel()
        complete(id, result: .failure(CancellationError()))
    }

    public func stop() async {
        stopped = true
        let active = Array(workers.values)
        for id in Array(flights.keys) { cancel(id) }
        for worker in active { worker.cancel() }
        for worker in active { await worker.value }
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }

    private func startNext() {
        while !stopped, workers.count < concurrency, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let flight = flights[id] else { continue }
            let request = flight.request
            let archive = archive
            let loader = loader
            workers[id] = Task.detached(priority: .utility) { [weak self] in
                let result: Result<ClipboardThumbnailSnapshot, Error>
                var key: String?
                do {
                    try Task.checkCancellation()
                    let entry = try archive.entry(id: request.entryID)
                    let version = try Self.version(entry, archive: archive)
                    key = version
                    if let hit = await self?.cached(version) {
                        result = .success(hit)
                    } else {
                        let payload = try archive.payload(id: entry.id)
                        let data = try await loader(payload)
                        try Task.checkCancellation()
                        guard (data?.count ?? 0) <= ClipboardThumbnailSnapshot.maximumBytes,
                            try Self.version(entry, archive: archive) == version
                        else {
                            throw AgentError(
                                .failed, "The clipboard preview changed while loading.")
                        }
                        result = .success(ClipboardThumbnailSnapshot(data: data))
                    }
                } catch { result = .failure(error) }
                await self?.finish(id, key: key, result: result)
            }
        }
    }

    private static func version(_ entry: ClipboardEntry, archive: ClipboardArchive) throws -> String
    {
        let base = entry.sha256 + "." + entry.ext
        guard entry.kind == .file, entry.ext == "url" else { return base }
        let payload = try archive.payload(id: entry.id)
        guard payload.data.count <= 16_384,
            let text = String(data: payload.data, encoding: .utf8),
            let url = URL(string: text), url.isFileURL
        else { return base }
        var value = stat()
        guard stat(url.path, &value) == 0 else { return base + ".missing" }
        guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else {
            throw AgentError(.refused, "Clipboard previews require a regular file or folder.")
        }
        return
            "\(base):\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    private func cached(_ key: String) -> ClipboardThumbnailSnapshot? {
        guard let hit = cache[key], hit.expires > Date() else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return hit.snapshot
    }

    private func remember(_ snapshot: ClipboardThumbnailSnapshot, key: String) {
        cacheBytes -= cache[key]?.snapshot.data?.count ?? 0
        cache[key] = Cached(
            snapshot: snapshot, expires: Date().addingTimeInterval(snapshot.data == nil ? 10 : 300))
        cacheBytes += snapshot.data?.count ?? 0
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 128 || cacheBytes > 8 << 20 {
            let removed = cacheOrder.removeFirst()
            cacheBytes -= cache.removeValue(forKey: removed)?.snapshot.data?.count ?? 0
        }
    }

    private func expire(_ id: UUID) {
        workers[id]?.cancel()
        complete(
            id,
            result: .failure(AgentError(.unavailable, "Loading the clipboard preview timed out.")))
    }

    private func finish(
        _ id: UUID, key: String?, result: Result<ClipboardThumbnailSnapshot, Error>
    ) {
        workers[id] = nil
        if flights[id] != nil, let key, case let .success(snapshot) = result {
            remember(snapshot, key: key)
        }
        complete(id, result: result)
        startNext()
    }

    private func complete(_ id: UUID, result: Result<ClipboardThumbnailSnapshot, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0 == id }
        flights.removeValue(forKey: id)?.continuation.resume(with: result)
    }

    deinit {
        for worker in workers.values { worker.cancel() }
        for deadline in deadlines.values { deadline.cancel() }
    }
}
