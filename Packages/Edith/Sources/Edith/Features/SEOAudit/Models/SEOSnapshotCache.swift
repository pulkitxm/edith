import AppKit
import Foundation

enum SEOSnapshotCache {
    static var decode: @Sendable (URL) -> NSImage? = { NSImage(contentsOf: $0) }

    private static let memory: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    static func image(for fileURL: URL) async -> NSImage? {
        let key = fileURL as NSURL
        if let cached = memory.object(forKey: key) { return cached }
        let loaded = await Task.detached(priority: .utility) {
            decode(fileURL)
        }.value
        if let loaded { memory.setObject(loaded, forKey: key) }
        return loaded
    }
}
