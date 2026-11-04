import AppKit

final class EmojiGlyphImages: @unchecked Sendable {
    static let shared = EmojiGlyphImages()
    static let pointSize: CGFloat = 22
    static let canvas = NSSize(width: 34, height: 34)

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    func image(for character: String) -> NSImage {
        let key = character as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = Self.render(character)
        cache.setObject(image, forKey: key, cost: Int(Self.canvas.width * Self.canvas.height) * 16)
        return image
    }

    private static func render(_ character: String) -> NSImage {
        let scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale),
            pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 32)!
        rep.size = canvas
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pointSize)
        ]
        let size = (character as NSString).size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (character as NSString).draw(
            at: NSPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2),
            withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        return image
    }
}
