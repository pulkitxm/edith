import AppKit
import CryptoKit
import EdithKit
import Foundation

actor AttentionFaviconStore {
    static let shared = AttentionFaviconStore()

    private let directory: URL
    private let session: URLSession
    private var memory: [URL: Data] = [:]
    private var downloads: [URL: Task<Data?, Never>] = [:]

    init(
        directory: URL = AttentionPaths.directory.appendingPathComponent("favicons"),
        session: URLSession = .shared
    ) {
        self.directory = directory
        self.session = session
    }

    func data(for url: URL) async -> Data? {
        if let cached = cachedData(for: url) { return cached }
        if let download = downloads[url] { return await download.value }
        let session = session
        let download = Task<Data?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                !data.isEmpty, data.count <= 2_000_000,
                (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                NSImage(data: data) != nil
            else { return nil }
            return data
        }
        downloads[url] = download
        let data = await download.value
        downloads[url] = nil
        if let data { try? store(data, for: url) }
        return data
    }

    func cachedData(for url: URL) -> Data? {
        if let data = memory[url] { return data }
        guard let data = try? Data(contentsOf: fileURL(for: url)), NSImage(data: data) != nil else {
            return nil
        }
        remember(data, for: url)
        return data
    }

    func store(_ data: Data, for url: URL) throws {
        guard !data.isEmpty, data.count <= 2_000_000, NSImage(data: data) != nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: url), options: .atomic)
        remember(data, for: url)
    }

    private func remember(_ data: Data, for url: URL) {
        if memory.count >= 256 { memory.removeAll(keepingCapacity: true) }
        memory[url] = data
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest)
    }
}
