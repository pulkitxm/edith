import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class CaptureLibraryModel {
    var items: [CaptureLibraryItem] = []

    func reload() {
        Task {
            items = await Task.detached(priority: .utility) {
                CaptureLibraryStore.load()
            }.value
        }
    }
}

@MainActor
final class CaptureLibraryController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model = CaptureLibraryModel()
    private let edit: (CaptureLibraryItem) -> Void
    private let pin: (Data) -> Void

    init(edit: @escaping (CaptureLibraryItem) -> Void, pin: @escaping (Data) -> Void) {
        self.edit = edit
        self.pin = pin
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        panel.title = "Recent Captures"
        panel.minSize = NSSize(width: 560, height: 400)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: CaptureLibraryView(
                model: model,
                copy: { [weak self] in self?.copy($0) },
                save: { [weak self] in self?.save($0) },
                edit: edit,
                pin: { [weak self] item in self?.pin(item) },
                delete: { [weak self] in self?.delete($0) },
                clear: { [weak self] in self?.clear() }))
    }

    func show() {
        model.reload()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        model.reload()
    }

    func close() {
        panel.close()
        panel.contentView = nil
    }

    private func withData(
        for item: CaptureLibraryItem, perform action: @escaping @MainActor (Data) -> Void
    ) {
        let url = CaptureLibraryStore.imageURL(for: item)
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            guard let data else {
                NSSound.beep()
                return
            }
            action(data)
        }
    }

    private func copy(_ item: CaptureLibraryItem) {
        withData(for: item) { data in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            IPC.post(IPC.Name.clipboardChanged)
        }
    }

    private func save(_ item: CaptureLibraryItem) {
        let sourceURL = CaptureLibraryStore.imageURL(for: item)
        Task {
            let savedURL: URL? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: sourceURL) else { return nil }
                return try? CaptureSaveLocation.save(data, mode: item.mode)
            }.value
            guard let savedURL else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        }
    }

    private func pin(_ item: CaptureLibraryItem) {
        withData(for: item) { [pin] data in
            pin(data)
        }
    }

    private func delete(_ item: CaptureLibraryItem) {
        performLibraryChange {
            try CaptureLibraryStore.remove(item)
        }
    }

    private func clear() {
        performLibraryChange {
            try CaptureLibraryStore.clear()
        }
    }

    private func performLibraryChange(_ action: @escaping @Sendable () throws -> Void) {
        Task {
            let succeeded = await Task.detached(priority: .userInitiated) {
                do {
                    try action()
                    return true
                } catch {
                    return false
                }
            }.value
            guard succeeded else {
                NSSound.beep()
                return
            }
            model.reload()
            IPC.post(IPC.Name.settingsChanged)
        }
    }
}

private struct CaptureLibraryView: View {
    @Bindable var model: CaptureLibraryModel
    let copy: (CaptureLibraryItem) -> Void
    let save: (CaptureLibraryItem) -> Void
    let edit: (CaptureLibraryItem) -> Void
    let pin: (CaptureLibraryItem) -> Void
    let delete: (CaptureLibraryItem) -> Void
    let clear: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Recent Captures", systemImage: "photo.stack")
                    .font(.title3.weight(.semibold))
                Text("\(model.items.count) of \(CaptureLibraryStore.maximumCount)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", role: .destructive, action: clear)
                    .disabled(model.items.isEmpty)
            }
            .padding(16)
            Divider()
            if model.items.isEmpty {
                ContentUnavailableView(
                    "No captures yet", systemImage: "camera.viewfinder",
                    description: Text("Area, window, and full-screen captures appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.items) { item in
                            CaptureLibraryCard(
                                item: item, copy: { copy(item) }, save: { save(item) },
                                edit: { edit(item) }, pin: { pin(item) },
                                delete: { delete(item) })
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

private struct CaptureLibraryCard: View {
    let item: CaptureLibraryItem
    let copy: () -> Void
    let save: () -> Void
    let edit: () -> Void
    let pin: () -> Void
    let delete: () -> Void

    private var url: URL { CaptureLibraryStore.imageURL(for: item) }
    private var image: NSImage { NSImage(contentsOf: url) ?? NSImage(size: .zero) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 150)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            HStack {
                Label(item.mode.displayName, systemImage: modeIcon)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(item.capturedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Button("Copy", action: copy)
                Button("Save", action: save)
                Button("Edit", action: edit)
                Button("Pin", action: pin)
                Spacer()
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var modeIcon: String {
        switch item.mode {
        case .area: "crop"
        case .window: "macwindow"
        case .screen: "display"
        }
    }
}
