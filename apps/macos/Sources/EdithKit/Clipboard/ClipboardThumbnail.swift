import AppKit
import QuickLookThumbnailing
import SwiftUI

public enum ClipboardThumbnail {
    public static let maxSize = NSSize(width: 340, height: 40)

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    public static func cached(for entry: ClipboardEntry) -> NSImage? {
        cache.object(forKey: entry.sha256 as NSString)
    }

    public static func thumbnail(for entry: ClipboardEntry) async -> NSImage? {
        if let hit = cached(for: entry) { return hit }
        let image: NSImage? =
            switch entry.kind {
            case .image: await renderImage(entry)
            case .file: await renderFile(entry)
            default: nil
            }
        if let image { cache.setObject(image, forKey: entry.sha256 as NSString) }
        return image
    }

    private static func renderImage(_ entry: ClipboardEntry) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let data = ClipboardRepository.blobData(for: entry),
                let image = NSImage(data: data)
            else { return nil }
            return downscale(image, toFit: maxSize)
        }.value
    }

    private static func renderFile(_ entry: ClipboardEntry) async -> NSImage? {
        guard let data = ClipboardRepository.blobData(for: entry),
            let string = String(data: data, encoding: .utf8),
            let url = URL(string: string), url.isFileURL
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 40, height: 40), scale: 2,
            representationTypes: [.thumbnail, .icon])
        if let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
        {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func downscale(_ image: NSImage, toFit bounds: NSSize) -> NSImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }
        let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        guard ratio < 1 else { return image }
        let target = NSSize(
            width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        guard
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(target.width * 2), pixelsHigh: Int(target.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        representation.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: target)
        output.addRepresentation(representation)
        return output
    }
}

public struct ClipboardThumbnailView<Placeholder: View>: View {
    private let entry: ClipboardEntry
    private let maxHeight: CGFloat
    private let placeholder: Placeholder

    @State private var image: NSImage?

    public init(
        entry: ClipboardEntry, maxHeight: CGFloat,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.entry = entry
        self.maxHeight = maxHeight
        self.placeholder = placeholder()
        _image = State(initialValue: ClipboardThumbnail.cached(for: entry))
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                placeholder
            }
        }
        .task(id: entry.sha256) {
            if image == nil {
                image = await ClipboardThumbnail.thumbnail(for: entry)
            }
        }
    }
}
