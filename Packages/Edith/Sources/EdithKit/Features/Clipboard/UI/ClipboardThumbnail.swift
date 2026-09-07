import AppKit
import SwiftUI

@MainActor public enum ClipboardThumbnail {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    public static func cached(for entry: ClipboardEntry) -> NSImage? {
        guard entry.kind == .image else { return nil }
        return cache.object(forKey: entry.sha256 as NSString)
    }

    public static func thumbnail(for entry: ClipboardEntry) async -> NSImage? {
        if let hit = cached(for: entry) { return hit }
        guard entry.kind == .image || entry.kind == .file else { return nil }
        do {
            let snapshot = try await AgentClipboardClient().thumbnail(id: entry.id)
            guard !Task.isCancelled, let data = snapshot.data, let image = NSImage(data: data)
            else {
                return nil
            }
            if entry.kind == .image {
                cache.setObject(image, forKey: entry.sha256 as NSString, cost: data.count * 4)
            }
            return image
        } catch { return nil }
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
                    .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(3)))
            } else {
                placeholder
            }
        }
        .task(id: entry.sha256) {
            if image == nil || entry.kind == .file {
                let loaded = await ClipboardThumbnail.thumbnail(for: entry)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }
}
