import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct SocialAvatar: View {
    let image: NSImage?
    let initials: String
    let name: String
    var size: CGFloat = 42
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(initials).font(.edithText(.caption).weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DashSkin.accent(scheme == .dark).opacity(0.15))
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size)).clipShape(Circle())
        .accessibilityLabel("Picture for \(name)")
    }
}

struct SocialPicturePicker: View {
    let savedImage: NSImage?
    @Binding var pictureURL: URL?
    @Binding var removingPicture: Bool
    var onError: (Error) -> Void
    @State private var choosingPicture = false
    @State private var preview: NSImage?

    var body: some View {
        HStack {
            if let image = preview ?? (removingPicture ? nil : savedImage) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: UIScale.pt(52), height: UIScale.pt(52)).clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle").font(.edithText(.largeTitle))
            }
            Button("Choose picture…") { choosingPicture = true }
            if preview != nil || (!removingPicture && savedImage != nil) {
                Button("Remove picture") {
                    pictureURL = nil
                    preview = nil
                    removingPicture = true
                }
            }
        }
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let data = try SocialAvatarFiles.thumbnail(url)
                preview = NSImage(data: data)
                pictureURL = url
                removingPicture = false
            } catch { onError(error) }
        }
    }
}

struct SocialPictureActions: View {
    let name: String
    let hasPicture: Bool
    let choose: (URL) -> Void
    let remove: () -> Void

    var body: some View {
        Button(hasPicture ? "Replace picture…" : "Choose picture…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a picture for \(name)"
            guard let window = NSApp.keyWindow else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                choose(url)
            }
        }
        if hasPicture { Button("Remove picture", action: remove) }
    }
}
