import AppKit
import AVFoundation
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class ScreenRecordingLibraryModel {
    var items: [ScreenRecordingTake] = []

    func reload() {
        items = ScreenRecordingLibrary.load()
    }
}

@MainActor
final class ScreenRecordingLibraryController {
    private let panel: NSPanel
    private let model = ScreenRecordingLibraryModel()
    private let open: (ScreenRecordingTake) -> Void

    init(open: @escaping (ScreenRecordingTake) -> Void) {
        self.open = open
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        panel.title = "Recent Recordings"
        panel.minSize = NSSize(width: 600, height: 400)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScreenRecordingLibraryView(
            model: model, open: open, copy: Self.copy,
            reveal: Self.reveal, delete: { [weak self] take in
                ScreenRecordingLibrary.remove(take)
                self?.reload()
            }))
    }

    func show() {
        reload()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() { model.reload() }

    func close() {
        panel.close()
        panel.contentView = nil
    }

    private static func copy(_ take: ScreenRecordingTake) {
        let url = ScreenRecordingLibrary.masterURL(for: take.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        IPC.post(IPC.Name.clipboardChanged)
    }

    private static func reveal(_ take: ScreenRecordingTake) {
        NSWorkspace.shared.activateFileViewerSelecting([
            ScreenRecordingLibrary.masterURL(for: take.id)
        ])
    }
}

private struct ScreenRecordingLibraryView: View {
    @Bindable var model: ScreenRecordingLibraryModel
    let open: (ScreenRecordingTake) -> Void
    let copy: (ScreenRecordingTake) -> Void
    let reveal: (ScreenRecordingTake) -> Void
    let delete: (ScreenRecordingTake) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Recent Recordings", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.items.count) of \(ScreenRecordingLibrary.maximumCount)")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if model.items.isEmpty {
                ContentUnavailableView(
                    "No recordings yet", systemImage: "video",
                    description: Text("Finished and recovered takes appear here."))
            } else {
                List(model.items) { take in
                    HStack(spacing: 12) {
                        Image(systemName: take.completedAt == nil ? "lifepreserver" : "video.fill")
                            .frame(width: 34, height: 34)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(take.completedAt == nil ? "Recovered recording" : take.source.displayName)
                                .font(.headline)
                            Text(
                                "\(take.duration, specifier: "%.1f") seconds, \(take.pixelWidth) × \(take.pixelHeight)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { open(take) }
                        Button { copy(take) } label: { Image(systemName: "doc.on.doc") }
                        Button { reveal(take) } label: { Image(systemName: "folder") }
                        Button(role: .destructive) { delete(take) } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
