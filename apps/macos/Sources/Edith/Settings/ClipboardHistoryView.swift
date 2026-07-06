import AppKit
import EdithKit
import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ClipboardEntry] = []
    @State private var filterText = ""
    @State private var refreshObserver: NSObjectProtocol?
    @State private var copiedID: String?

    private var filtered: [ClipboardEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = entries.filter { entry in
            query.isEmpty
                || (entry.preview?.lowercased().contains(query) ?? false)
                || (entry.sourceApp?.lowercased().contains(query) ?? false)
        }
        return matched.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clipboard History").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .pointerCursor()
            }
            .padding()
            Divider()
            TextField("Search…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(filtered) { entry in
                row(entry)
            }
            .listStyle(.inset)
        }
        .frame(width: 480, height: 520)
        .onAppear {
            reload()
            refreshObserver = IPC.observe(IPC.Name.clipboardChanged) { reload() }
        }
        .onDisappear {
            if let refreshObserver { IPC.stopObserving(refreshObserver) }
            refreshObserver = nil
        }
    }

    private func reload() {
        entries = ClipboardRepository.loadEntries()
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ClipboardThumbnailView(entry: entry, maxHeight: entry.kind == .text ? 18 : 40) {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .frame(minWidth: 18)
            VStack(alignment: .leading, spacing: 3) {
                if entry.kind != .image {
                    Text(entry.preview ?? "").lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(entry.sourceApp ?? "Unknown")
                    Text("·")
                    Text(entry.createdAt.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text(Self.byteCountFormatter.string(fromByteCount: Int64(entry.size)))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if copiedID == entry.id {
                Text("Copied").font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                copy(entry)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain).pointerCursor()
            Button {
                togglePin(entry)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).pointerCursor()
            Button(role: .destructive) {
                delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).pointerCursor()
        }
        .padding(.vertical, 4)
    }

    private func icon(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .file: return "doc"
        case .richText, .html: return "doc.richtext"
        case .text: return "doc.plaintext"
        }
    }

    private func copy(_ entry: ClipboardEntry) {
        let plain = SharedDefaults.store.bool(forKey: "clipboardPastePlainText")
        ClipboardRepository.copyToPasteboard(entry, asPlainText: plain)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private func togglePin(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].pinned.toggle()
        persist()
    }

    private func delete(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        persist(pruneBlobs: true)
    }

    private func persist(pruneBlobs: Bool = false) {
        try? ClipboardRepository.saveEntries(entries)
        if pruneBlobs { ClipboardRepository.pruneOrphanBlobs(keeping: entries) }
        IPC.post(IPC.Name.clipboardChanged)
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
