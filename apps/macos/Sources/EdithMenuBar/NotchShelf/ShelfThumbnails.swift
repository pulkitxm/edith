import AppKit
import QuickLookThumbnailing

@MainActor
enum ShelfThumbnails {
    private static var cache: [String: NSImage] = [:]

    private static let maxEntries = 200

    static func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache[url.path] { return cached }
        if cache.count >= maxEntries { cache.removeAll() }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 76, height: 76),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
            for: request)
        guard let image = generated?.nsImage else { return nil }
        cache[url.path] = image
        return image
    }
}
