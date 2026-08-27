import AppKit
import EdithKit
import SwiftUI

@MainActor
final class CapturePreviewController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var timer: Timer?

    init(
        image: NSImage, pngData: Data, recognition: CaptureRecognition,
        operation: CaptureToolOperation, copiedResult: Bool
    ) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: CapturePreviewView(
                image: image, recognition: recognition, operation: operation,
                copiedResult: copiedResult,
                copyImage: { Self.copyImage(pngData) },
                saveImage: { Self.saveImage(pngData) },
                copyResult: { Self.copyResult(recognition.output(for: .smart)) },
                openResult: { Self.openResult(recognition) },
                discard: { [weak self] in self?.close() },
                hovering: { [weak self] inside in self?.setHovering(inside) }))
    }

    func show() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = panel.frame
            let visible = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24))
        }
        panel.orderFrontRegardless()
        scheduleClose()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.close()
        panel.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        panel.contentView = nil
    }

    private func setHovering(_ hovering: Bool) {
        if hovering {
            timer?.invalidate()
            timer = nil
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private static func copyImage(_ data: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        IPC.post(IPC.Name.clipboardChanged)
    }

    private static func saveImage(_ data: Data) {
        guard let url = try? CaptureScreenshotArchive.save(data) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func copyResult(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        IPC.post(IPC.Name.clipboardChanged)
    }

    private static func openResult(_ recognition: CaptureRecognition) {
        guard recognition.codes.count == 1,
            let url = CaptureRecognizedLink.openable(recognition.codes[0].payload)
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct CapturePreviewView: View {
    let image: NSImage
    let recognition: CaptureRecognition
    let operation: CaptureToolOperation
    let copiedResult: Bool
    let copyImage: () -> Void
    let saveImage: () -> Void
    let copyResult: () -> Void
    let openResult: () -> Void
    let discard: () -> Void
    let hovering: (Bool) -> Void

    private var output: String { recognition.output(for: .smart) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    operation == .read ? "Screen read" : "Screenshot",
                    systemImage: operation == .read ? "text.viewfinder" : "camera.viewfinder")
                    .font(.headline)
                Spacer()
                if copiedResult {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 178)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(output.isEmpty ? "No text or codes found" : output)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(output.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Copy image", action: copyImage)
                Button("Save", action: saveImage)
                if !output.isEmpty { Button("Copy result", action: copyResult) }
                if recognition.codes.count == 1,
                    CaptureRecognizedLink.openable(recognition.codes[0].payload) != nil
                {
                    Button("Open", action: openResult)
                }
                Spacer()
                Button("Discard", role: .destructive, action: discard)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(18)
        .onHover(perform: hovering)
    }
}
