import AppKit
import SwiftUI
import EdithExtensionUI

struct EmbeddedDownloadImage<Placeholder: View>: View {
    var url: URL
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { placeholder() }
        }
        .pageTask(id: url) {
            image = nil
            guard let payload = try? JSONEncoder().encode(url),
                let data = try? await EmbeddedMusicRemote.shared.dataRequest(
                    "music.ui.downloads.thumbnail", payload: payload),
                let bytes = try? JSONDecoder().decode(Data.self, from: data),
                bytes.count <= 1_048_576, !Task.isCancelled
            else { return }
            image = NSImage(data: bytes)
        }
    }
}
