import AppKit
import QuickLookThumbnailing

struct ShelfThumbnailLRUCache<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    private var accessOrder: [Key] = []

    var count: Int { values.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        recordAccess(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key, maxEntries: Int) {
        values[key] = value
        recordAccess(key)
        let limit = max(0, maxEntries)
        while values.count > limit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    private mutating func recordAccess(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

@MainActor
enum ShelfThumbnails {
    private static var cache = ShelfThumbnailLRUCache<String, NSImage>()

    private static let maxEntries = 200

    static func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.value(for: url.path) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 76, height: 76),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
            for: request)
        guard let image = generated?.nsImage else { return nil }
        cache.insert(image, for: url.path, maxEntries: maxEntries)
        return image
    }
}
