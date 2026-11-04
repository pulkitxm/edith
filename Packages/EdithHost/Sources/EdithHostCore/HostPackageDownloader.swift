import Darwin
import ExtensionMarketplace
import Foundation

public struct HostPackageDownloader: Sendable {
    public typealias Progress = @Sendable (Int64) -> Void

    public let connections: Int
    public let segmentBytes: Int64
    public let minimumSegmentBytes: Int64
    public let probeBytes: Int64
    public let attempts: Int
    public let idleTimeout: TimeInterval
    private let configuration: @Sendable () -> URLSessionConfiguration

    public init(
        connections: Int = 8, segmentBytes: Int64 = 512 * 1024,
        minimumSegmentBytes: Int64 = 128 * 1024, probeBytes: Int64 = 64 * 1024,
        attempts: Int = 6, idleTimeout: TimeInterval = 20,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.connections = max(1, connections)
        self.segmentBytes = max(1, segmentBytes)
        self.minimumSegmentBytes = max(1, min(minimumSegmentBytes, segmentBytes))
        self.probeBytes = max(1, probeBytes)
        self.attempts = max(1, attempts)
        self.idleTimeout = idleTimeout
        self.configuration = configuration
    }

    public func download(
        _ url: URL, expectedBytes: Int64, progress: @escaping Progress = { _ in }
    ) async throws -> URL {
        guard expectedBytes > 0 else { throw MarketplaceError.downloadFailed }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-download-\(UUID().uuidString).zip")
        let output = try HostDownloadFile(url: destination, size: expectedBytes)
        var completed = false
        defer {
            output.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        let counter = HostTransferCounter(report: progress)
        var segments = plan(expectedBytes)
        let first = segments.removeFirst()
        let probe = session()
        defer { probe.invalidateAndCancel() }
        let ranged = try await fetch(
            first, url: url, total: expectedBytes, session: probe, output: output,
            counter: counter)
        if ranged, !segments.isEmpty {
            let queue = HostSegmentQueue(segments)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await drain(
                        queue, url: url, total: expectedBytes, session: probe, output: output,
                        counter: counter)
                }
                for _ in 1..<min(connections, segments.count + 1) {
                    group.addTask {
                        let worker = session()
                        defer { worker.invalidateAndCancel() }
                        try await drain(
                            queue, url: url, total: expectedBytes, session: worker,
                            output: output, counter: counter)
                    }
                }
                try await group.waitForAll()
            }
        }
        guard counter.received == expectedBytes else { throw MarketplaceError.downloadFailed }
        counter.flush()
        completed = true
        return destination
    }

    func plan(_ total: Int64) -> [Range<Int64>] {
        let probe = min(probeBytes, total)
        let remaining = total - probe
        let share = (remaining + Int64(connections * 4) - 1) / Int64(connections * 4)
        let size = min(segmentBytes, max(minimumSegmentBytes, share))
        return [0..<probe]
            + stride(from: probe, to: total, by: Int(size)).map { $0..<min($0 + size, total) }
    }

    private func session() -> URLSession {
        let configuration = configuration()
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private func drain(
        _ queue: HostSegmentQueue, url: URL, total: Int64, session: URLSession,
        output: HostDownloadFile, counter: HostTransferCounter
    ) async throws {
        while let segment = queue.next() {
            try Task.checkCancellation()
            guard
                try await fetch(
                    segment, url: url, total: total, session: session, output: output,
                    counter: counter)
            else { throw MarketplaceError.downloadFailed }
        }
    }

    private func fetch(
        _ segment: Range<Int64>, url: URL, total: Int64, session: URLSession,
        output: HostDownloadFile, counter: HostTransferCounter
    ) async throws -> Bool {
        var offset = segment.lowerBound
        var failures = 0
        while true {
            let start = offset
            var whole = false
            do {
                var request = URLRequest(
                    url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: idleTimeout)
                request.setValue("Edith", forHTTPHeaderField: "User-Agent")
                request.setValue(
                    "bytes=\(offset)-\(segment.upperBound - 1)", forHTTPHeaderField: "Range")
                for try await event in HostTransferEvents.stream(request, session: session) {
                    switch event {
                    case .response(let response):
                        whole = try Self.admit(
                            response, offset: offset, total: total,
                            allowsWhole: segment.lowerBound == 0 && offset == 0)
                    case .data(let data):
                        let limit = whole ? total : segment.upperBound
                        guard offset + Int64(data.count) <= limit else {
                            throw MarketplaceError.downloadFailed
                        }
                        try output.write(data, at: offset)
                        offset += Int64(data.count)
                        counter.add(Int64(data.count))
                    }
                }
                guard offset == (whole ? total : segment.upperBound) else {
                    throw URLError(.networkConnectionLost)
                }
                return !whole
            } catch {
                try Task.checkCancellation()
                if whole {
                    counter.add(segment.lowerBound - offset)
                    offset = segment.lowerBound
                }
                failures = offset > start ? 1 : failures + 1
                guard Self.transient(error), failures < attempts else { throw error }
                try await Task.sleep(for: .milliseconds(400 * failures))
            }
        }
    }

    static func admit(
        _ response: HTTPURLResponse, offset: Int64, total: Int64, allowsWhole: Bool
    ) throws -> Bool {
        switch response.statusCode {
        case 206:
            guard
                let range = response.value(forHTTPHeaderField: "Content-Range"),
                let parsed = HostContentRange(range), parsed.start == offset,
                parsed.total == total
            else { throw MarketplaceError.downloadFailed }
            return false
        case 200:
            guard allowsWhole,
                response.expectedContentLength < 0 || response.expectedContentLength == total
            else { throw MarketplaceError.downloadFailed }
            return true
        case 403, 429: throw MarketplaceError.rateLimited
        case 500...599: throw URLError(.badServerResponse)
        default: throw MarketplaceError.downloadFailed
        }
    }

    static func transient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return error.code != .cancelled
    }
}

struct HostContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ header: String) {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
            start <= end, end < total
        else { return nil }
        self.start = start
        self.end = end
        self.total = total
    }
}

enum HostTransferEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

enum HostTransferEvents {
    static func stream(_ request: URLRequest, session: URLSession)
        -> AsyncThrowingStream<HostTransferEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            task.delegate = HostTransferRelay(continuation: continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
}

private final class HostTransferRelay: NSObject, URLSessionDataDelegate, Sendable {
    let continuation: AsyncThrowingStream<HostTransferEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<HostTransferEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: MarketplaceError.downloadFailed)
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        continuation.finish(throwing: error)
    }
}

final class HostTransferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let report: HostPackageDownloader.Progress
    private var total: Int64 = 0
    private var reported: ContinuousClock.Instant?

    init(report: @escaping HostPackageDownloader.Progress) { self.report = report }

    var received: Int64 { lock.withLock { total } }

    func add(_ bytes: Int64) {
        let now = ContinuousClock.now
        let value: Int64? = lock.withLock {
            total += bytes
            if let reported, now - reported < .milliseconds(200) { return nil }
            reported = now
            return total
        }
        if let value { report(value) }
    }

    func flush() { report(received) }
}

final class HostSegmentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Range<Int64>]

    init(_ segments: [Range<Int64>]) { pending = segments.reversed() }

    func next() -> Range<Int64>? { lock.withLock { pending.popLast() } }
}

final class HostDownloadFile: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL, size: Int64) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = pwrite(
                    descriptor, base + written, buffer.count - written,
                    off_t(offset) + off_t(written))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CocoaError(.fileWriteUnknown)
                }
                written += count
            }
        }
    }

    func close() { Darwin.close(descriptor) }
}
