import AppKit
import EdithKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
enum VideoProjectThumbnails {
    private static var images: [URL: NSImage] = [:]

    static func cached(_ url: URL?) -> NSImage? {
        url.flatMap { images[$0] }
    }

    static func store(_ image: NSImage, for url: URL) {
        images[url] = image
    }

    static func image(for url: URL) async -> NSImage? {
        if let cached = images[url] { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 320, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard
            let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            ).nsImage
        else { return nil }
        images[url] = image
        return image
    }
}

struct VideoProjectCard: View {
    let listing: VideoProject.Listing
    let open: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    init(listing: VideoProject.Listing, open: @escaping () -> Void) {
        self.listing = listing
        self.open = open
        _image = State(initialValue: VideoProjectThumbnails.cached(listing.previewURL))
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Color.black
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: UIScale.pt(26), weight: .light))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(8))
                            .strokeBorder(
                                hovering ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: hovering ? 2 : 1)
                    }
                Text(listing.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: UIScale.pt(6)) {
                    Text("Edited \(listing.modified.formatted(.relative(presentation: .named)))")
                    if listing.isOpenScreenLibrary {
                        Text("OpenScreen")
                            .padding(.horizontal, UIScale.pt(5))
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .onHover { hovering = $0 }
        .task(id: listing.previewURL) {
            guard image == nil, let url = listing.previewURL else { return }
            image = await VideoProjectThumbnails.image(for: url)
        }
    }
}
