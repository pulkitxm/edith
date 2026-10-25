import AppKit
import EdithExtensionSupport
import Foundation
import ImageIO

final class SEOSnapshotCache: @unchecked Sendable {
    static let shared = SEOSnapshotCache()
    private let lock = NSLock()
    private let memory = NSCache<NSURL, NSImage>()
    private var root: URL
    private var network: SEOAuditHTTPClient?
    private var generation = 0
    private var stopped = false
    private var remote: (@Sendable (URL) async throws -> Data?)?
    private var remoteOwners: [(UUID, @Sendable (URL) async throws -> Data?)] = []

    init(
        root: URL = ExtensionData.root.appendingPathComponent("SEOAudit"),
        network: SEOAuditHTTPClient? = nil
    ) {
        self.root = root; self.network = network
        memory.countLimit = 100; memory.totalCostLimit = 64 * 1_024 * 1_024
    }

    func configure(root: URL, network: SEOAuditHTTPClient) {
        lock.withLock {
            generation += 1; stopped = false; self.root = root; self.network = network
            memory.removeAllObjects()
        }
    }

    func configureRemote(
        owner: UUID = UUID(), _ read: @escaping @Sendable (URL) async throws -> Data?
    ) {
        lock.withLock {
            remoteOwners.removeAll { $0.0 == owner }
            remoteOwners.append((owner, read))
            generation += 1; stopped = false; remote = read; network = nil;
            memory.removeAllObjects()
        }
    }

    func releaseRemote(_ owner: UUID) {
        lock.withLock {
            remoteOwners.removeAll { $0.0 == owner }
            remote = remoteOwners.last?.1
            generation += 1
            memory.removeAllObjects()
        }
    }

    func shutdown() {
        lock.withLock {
            stopped = true; generation += 1; network = nil; remote = nil; remoteOwners = [];
            memory.removeAllObjects()
        }
    }

    static func image(for fileURL: URL) async -> NSImage? { await shared.image(for: fileURL) }

    func image(for url: URL) async -> NSImage? {
        let state = lock.withLock { stopped ? nil : (generation, root, network, remote) }
        guard let state, !Task.isCancelled else { return nil }
        if let image = memory.object(forKey: url as NSURL) { return image }
        let data: Data?
        if let remote = state.3 {
            data = try? await remote(url)
        } else if url.isFileURL {
            data = await BlockingWork.value {
                SEOAuditOwnedIO.read(url, root: state.1, limit: 25 * 1_024 * 1_024)
            }
        } else {
            guard let network = state.2 else { return nil }
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard
                let response = try? await network.data(
                    for: request, maximumBytes: 25 * 1_024 * 1_024),
                let http = response.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                http.mimeType?.hasPrefix("image/") == true
            else { return nil }
            data = response.0
        }
        guard let data, !Task.isCancelled else { return nil }
        let image = await BlockingWork.value { Self.decode(data) }
        guard let image, !Task.isCancelled else { return nil }
        return lock.withLock {
            guard !stopped, generation == state.0 else { return nil }
            memory.setObject(
                image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
            return image
        }
    }

    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= 25 * 1_024 * 1_024,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 64_000_000 / height,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_048,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
