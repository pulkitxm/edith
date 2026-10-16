@preconcurrency import AVFoundation
import CoreGraphics
import Darwin
import Foundation

final class VideoFallbackFrameCache: @unchecked Sendable {
    struct Statistics {
        let requests: Int
        let hits: Int
        let decodes: Int
        let invalidations: Int
        let entries: Int
        let bytes: Int
        let peakBytes: Int
    }

    private struct Entry {
        let source: UUID
        let time: CMTime
        let image: CGImage
        let cost: Int
    }

    static let maximumBytes = 64 * 1024 * 1024
    static let maximumEntries = 64
    private let lock = NSLock()
    private var scopes: Set<UUID> = []
    private var generation: UInt64 = 0
    private var entries: [Entry] = []
    private var bytes = 0
    private var peakBytes = 0
    private var requests = 0
    private var hits = 0
    private var decodes = 0
    private var invalidations = 0

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                requests: requests, hits: hits, decodes: decodes,
                invalidations: invalidations, entries: entries.count,
                bytes: bytes, peakBytes: peakBytes)
        }
    }

    func begin() -> UUID {
        lock.withLock {
            if scopes.isEmpty {
                generation &+= 1
                requests = 0
                hits = 0
                decodes = 0
                invalidations = 0
                peakBytes = 0
            }
            let scope = UUID()
            scopes.insert(scope)
            return scope
        }
    }

    func end(_ scope: UUID) {
        lock.withLock {
            guard scopes.remove(scope) != nil else { return }
            generation &+= 1
            entries.removeAll()
            bytes = 0
        }
    }

    func lookup(source: UUID, time: CMTime) -> (CGImage?, UInt64?) {
        lock.withLock {
            guard !scopes.isEmpty, time.isNumeric else { return (nil, nil) }
            requests += 1
            guard let index = entries.firstIndex(where: { $0.source == source && $0.time == time })
            else { return (nil, generation) }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return (entry.image, generation)
        }
    }

    func recordHit(generation token: UInt64?) -> Bool {
        lock.withLock {
            guard !scopes.isEmpty, token == generation else { return false }
            hits += 1
            return true
        }
    }

    func recordDecode(generation token: UInt64?) {
        lock.withLock {
            if !scopes.isEmpty, token == generation { decodes += 1 }
        }
    }

    func store(_ image: CGImage, source: UUID, time: CMTime, generation token: UInt64?) {
        lock.withLock {
            guard !scopes.isEmpty, token == generation, time.isNumeric else { return }
            let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            guard !overflow, cost > 0, cost <= Self.maximumBytes else { return }
            if let index = entries.firstIndex(where: { $0.source == source && $0.time == time }) {
                bytes -= entries.remove(at: index).cost
            }
            while !entries.isEmpty
                && (entries.count >= Self.maximumEntries || cost > Self.maximumBytes - bytes)
            {
                bytes -= entries.removeFirst().cost
            }
            entries.append(Entry(source: source, time: time, image: image, cost: cost))
            bytes += cost
            peakBytes = max(peakBytes, bytes)
        }
    }

    func invalidate(source: UUID) {
        lock.withLock {
            generation &+= 1
            entries.removeAll { $0.source == source }
            bytes = entries.reduce(0) { $0 + $1.cost }
            if !scopes.isEmpty { invalidations += 1 }
        }
    }
}

final class VideoFallbackFrameSource: @unchecked Sendable {
    private struct InputRevision: Equatable {
        let device: dev_t
        let inode: ino_t
        let bytes: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ url: URL?) {
            guard let url else { return nil }
            var info = stat()
            guard
                url.withUnsafeFileSystemRepresentation({ path in
                    guard let path else { return false }
                    return fstatat(AT_FDCWD, path, &info, 0) == 0
                }), info.st_mode & S_IFMT == S_IFREG
            else { return nil }
            device = info.st_dev
            inode = info.st_ino
            bytes = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private let lock = NSLock()
    private let cache: VideoFallbackFrameCache
    private let source = UUID()
    private let url: URL?
    private var revision: InputRevision?
    private var generator: AVAssetImageGenerator

    init(asset: AVAsset, cache: VideoFallbackFrameCache) {
        generator = AVAssetImageGenerator(asset: asset)
        url = (asset as? AVURLAsset)?.url
        revision = InputRevision(url)
        self.cache = cache
    }

    private func refresh(_ current: InputRevision?) {
        guard current != revision else { return }
        cache.invalidate(source: source)
        revision = current
        if let url {
            generator.cancelAllCGImageGeneration()
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        }
    }

    func frame(at time: Double) -> CGImage? {
        lock.withLock {
            var current = InputRevision(url)
            refresh(current)
            let requested = CMTime(seconds: time, preferredTimescale: 600)
            let (cached, token) = cache.lookup(source: source, time: requested)
            if let cached, current != nil, current == InputRevision(url),
                cache.recordHit(generation: token)
            {
                return cached
            }
            let latest = InputRevision(url)
            if latest != current { refresh(latest); current = latest }
            cache.recordDecode(generation: token)
            guard let image = try? generator.copyCGImage(at: requested, actualTime: nil) else {
                return nil
            }
            if current != nil, current == InputRevision(url) {
                cache.store(image, source: source, time: requested, generation: token)
            }
            return image
        }
    }
}
