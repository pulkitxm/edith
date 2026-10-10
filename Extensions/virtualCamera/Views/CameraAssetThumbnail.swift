import AppKit
import EdithExtensionUI
import ImageIO
import SwiftUI

struct CameraAssetThumbnail: View {
    let url: URL
    var side: CGFloat = 160
    var corner: CGFloat = 10
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(corner)).fill(DashSkin.grid(scheme == .dark))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .padding(UIScale.pt(6)).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            } else {
                Image(systemName: "photo").font(
                    .system(size: UIScale.pt(side * 0.22), weight: .light)
                )
                .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(corner)))
        .pageTask(id: url) {
            let size = min(1024, max(1, Int(UIScale.pt(side) * 2)))
            let loaded = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: size,
                        ] as CFDictionary)
                else { return nil as NSImage? }
                return NSImage(
                    cgImage: thumbnail,
                    size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
