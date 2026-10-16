import AppKit
import EdithExtensionUI
import SwiftUI

struct EmbeddedDownloadImage<Placeholder: View>: View {
    var url: URL
    var height: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                placeholder()
            } else {
                SkeletonGroup {
                    SkeletonBlock(
                        width: Double(height) * 16 / 9 / UIScale.current,
                        height: Double(height) / UIScale.current, corner: 5)
                }
            }
        }
        .pageTask(id: url) {
            image = nil
            failed = false
            guard let payload = try? JSONEncoder().encode(url),
                let data = try? await EmbeddedMusicRemote.shared.dataRequest(
                    "music.ui.downloads.thumbnail", payload: payload),
                let bytes = try? JSONDecoder().decode(Data.self, from: data),
                bytes.count <= 1_048_576, !Task.isCancelled
            else {
                if !Task.isCancelled { failed = true }
                return
            }
            if let decoded = NSImage(data: bytes) { image = decoded } else { failed = true }
        }
    }
}
