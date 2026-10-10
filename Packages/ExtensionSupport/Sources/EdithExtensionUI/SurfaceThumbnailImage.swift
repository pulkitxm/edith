import CoreGraphics
import EdithExtensionSupport
import SwiftUI

struct SurfaceThumbnailImage: View {
    let thumbnail: SurfaceThumbnail
    let dense: Bool
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: UIScale.pt(dense ? 36 : 52), height: UIScale.pt(dense ? 36 : 52))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thumbnail.accessibilityLabel)
        .task(id: thumbnail.data) {
            image = nil
            guard !Task.isCancelled else { return }
            let decoded = try? thumbnail.decodedImage(maximumDimension: 160)
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .onDisappear { image = nil }
    }
}
