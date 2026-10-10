import AppKit
import EdithExtensionUI
import ImageIO
import SwiftUI

struct CameraAssetThumbnail: View {
    let model: VirtualCameraPageModel
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
            let loaded = await model.assetThumbnail(url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
