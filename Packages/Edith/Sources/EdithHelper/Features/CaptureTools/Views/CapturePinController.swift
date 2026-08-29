import AppKit
import SwiftUI

@MainActor
final class CapturePinController: NSObject, NSWindowDelegate {
    private let panel: NSPanel

    init?(data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        let ratio = max(0.2, min(5, image.size.width / max(image.size.height, 1)))
        let width = min(640, max(240, image.size.width))
        let size = NSSize(width: width, height: width / ratio)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .background(.black.opacity(0.08)))
        panel.contentAspectRatio = image.size
    }

    func show() {
        panel.center()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
        panel.contentView = nil
    }
}
