import EdithKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private actor FaviconPermits {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
}

public actor FaviconService {
    public static let maximumInputBytes = 1 << 20
    public static let maximumImageBytes = 128 << 10
    private struct Cached {
        let data: Data?
        let expires: Date
    }
    private let session: URLSession
    private let permits = FaviconPermits()
    private var pending: [URL: Task<Data?, Error>] = [:]
    private var cached: [URL: Cached] = [:]
    private var order: [URL] = []
    private var stopped = false

    public init(
        directory: URL = DataRoot.caches.appendingPathComponent("favicons"),
        configuration: URLSessionConfiguration? = nil
    ) {
        let config = configuration ?? .default
        config.urlCache = URLCache(
            memoryCapacity: 4 << 20, diskCapacity: 32 << 20, directory: directory)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }

    public func register(on runtime: AgentRuntime) async {
        await runtime.register(operation: AgentFaviconClient.operation) { payload in
            let url = try AgentPayload.decode(URL.self, from: payload)
            return try await AgentPayload.encode(self.data(for: url))
        }
        await runtime.registerShutdown(id: AgentFaviconClient.operation) { await self.stop() }
    }

    public func data(for url: URL) async throws -> Data? {
        guard !stopped else { throw AgentError(.unavailable, "The favicon service is stopping.") }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, url.user == nil, url.password == nil,
            url.absoluteString.utf8.count <= 8_192
        else { throw AgentError(.refused, "The favicon URL is invalid.") }
        if let value = cached[url], value.expires > Date() { return value.data }
        if let task = pending[url] { return try await task.value }
        guard pending.count < 32 else {
            throw AgentError(.unavailable, "The favicon request queue is full.")
        }
        let session = session
        let permits = permits
        let task = Task.detached(priority: .utility) {
            await permits.acquire()
            do {
                try Task.checkCancellation()
                let data = try await Self.fetch(url, session: session)
                try Task.checkCancellation()
                let image = Self.thumbnail(data)
                await permits.release()
                return image
            } catch {
                await permits.release()
                throw error
            }
        }
        pending[url] = task
        defer { pending[url] = nil }
        do {
            let data = try await task.value
            guard !stopped else { throw CancellationError() }
            remember(data, url: url)
            return data
        } catch {
            if !stopped, !(error is CancellationError) { remember(nil, url: url) }
            throw error
        }
    }

    public func stop() async {
        stopped = true
        let tasks = Array(pending.values)
        tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
        for task in tasks { _ = try? await task.value }
        pending.removeAll()
        cached.removeAll()
        order.removeAll()
    }

    private func remember(_ data: Data?, url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
        cached[url] = Cached(
            data: data, expires: Date().addingTimeInterval(data == nil ? 30 : 3_600))
        while order.count > 64 { cached[order.removeFirst()] = nil }
    }

    static let readChunkBytes = 16 * 1_024

    static func collect<Chunks: AsyncSequence & Sendable>(
        _ chunks: Chunks, limit: Int
    ) async throws -> Data where Chunks.Element == Data {
        var data = Data()
        var reads = 0
        for try await chunk in chunks {
            try Task.checkCancellation()
            reads += 1
            guard !chunk.isEmpty else { continue }
            guard chunk.count <= limit, data.count <= limit - chunk.count else {
                throw AgentError(.refused, "The favicon exceeds its transfer limit.")
            }
            data.append(chunk)
        }
        let allowed = max(1, (max(data.count, 1) + readChunkBytes - 1) / readChunkBytes) + 1
        guard reads <= allowed else {
            throw AgentError(.failed, "The favicon was read one byte at a time.")
        }
        return data
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw AgentError(.failed, "The favicon server did not return an image.")
        }
        guard data.count <= maximumInputBytes else {
            throw AgentError(.refused, "The favicon exceeds its transfer limit.")
        }
        let chunks = AsyncStream<Data> { continuation in
            var offset = 0
            while offset < data.count {
                let end = min(offset + readChunkBytes, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
        return try await collect(chunks, limit: maximumInputBytes)
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumImageBytes else {
            return nil
        }
        return output as Data
    }

    deinit {
        pending.values.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }
}
