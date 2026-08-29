import AppKit
import EdithKit
import SwiftUI

@MainActor
final class CapturePreviewController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var timer: Timer?

    init(
        item: CaptureLibraryItem?, image: NSImage, pngData: Data,
        recognition: CaptureRecognition, operation: CaptureToolOperation,
        copyMode: CaptureCopyMode, copiedResult: Bool,
        edit: @escaping (CaptureLibraryItem) -> Void,
        pin: @escaping (Data) -> Void,
        delete: @escaping (CaptureLibraryItem) -> Void
    ) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
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
                copyMode: copyMode, copiedResult: copiedResult,
                copyImage: { Self.copyImage(pngData) },
                saveImage: { Self.saveImage(pngData, mode: item?.mode ?? .area) },
                copyResult: { Self.copyResult(recognition.output(for: copyMode)) },
                openResult: { Self.openResult(recognition) },
                edit: { [weak self] in
                    if let item { edit(item) }
                    self?.close()
                },
                pin: { pin(pngData) },
                delete: { [weak self] in
                    if let item { delete(item) }
                    self?.close()
                },
                dragURL: item.map { CaptureLibraryStore.imageURL(for: $0) },
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

    private static func saveImage(_ data: Data, mode: CaptureMode) {
        guard let url = try? CaptureSaveLocation.save(data, mode: mode) else {
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
    let copyMode: CaptureCopyMode
    let copiedResult: Bool
    let copyImage: () -> Void
    let saveImage: () -> Void
    let copyResult: () -> Void
    let openResult: () -> Void
    let edit: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    let dragURL: URL?
    let discard: () -> Void
    let hovering: (Bool) -> Void

    private var output: String { recognition.output(for: copyMode) }
    private var resultIsPrimary: Bool { operation == .read && !output.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    operation == .read
                        ? "Screen read" : "\(operation.captureMode?.displayName ?? "Area") capture",
                    systemImage: operation == .read ? "text.viewfinder" : "camera.viewfinder"
                )
                .font(.headline)
                Spacer()
                if copiedResult {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if !recognition.codes.isEmpty {
                    Label("\(recognition.codes.count)", systemImage: "qrcode")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 178)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onDrag {
                    dragURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
                }
            Text(output.isEmpty ? "No text or codes found" : output)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(output.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(resultIsPrimary ? "Copy result" : "Copy image") {
                    resultIsPrimary ? copyResult() : copyImage()
                }
                .keyboardShortcut("c", modifiers: .command)
                if resultIsPrimary {
                    Button("Copy image", action: copyImage)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                } else if !output.isEmpty {
                    Button("Copy result", action: copyResult)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                Button("Save", action: saveImage)
                    .keyboardShortcut("s", modifiers: .command)
                if dragURL != nil {
                    Button("Edit", action: edit)
                    Button("Pin", action: pin)
                }
                if recognition.codes.count == 1,
                    CaptureRecognizedLink.openable(recognition.codes[0].payload) != nil
                {
                    Button("Open", action: openResult)
                        .keyboardShortcut("o", modifiers: .command)
                }
                Spacer()
                Button(dragURL == nil ? "Close" : "Delete", role: .destructive) {
                    dragURL == nil ? discard() : delete()
                }
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(18)
        .onHover(perform: hovering)
    }
}
