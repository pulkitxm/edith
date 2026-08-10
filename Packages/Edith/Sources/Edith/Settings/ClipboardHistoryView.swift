import AppKit
import EdithKit
import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @State private var entries: [ClipboardEntry] = []
    @State private var filterText = ""
    @State private var refreshObserver: NSObjectProtocol?
    @State private var copiedID: String?

    private var filtered: [ClipboardEntry] {
        ClipboardActions.arrange(entries, query: filterText)
    }

    private var summary: String {
        let stats = ClipboardActions.stats(entries)
        var parts = [stats.count == 1 ? "1 item" : "\(stats.count) items"]
        parts.append(Self.byteCountFormatter.string(fromByteCount: Int64(stats.bytes)))
        if stats.pinned > 0 { parts.append("\(stats.pinned) pinned") }
        let shown = filtered.count
        if shown != stats.count { parts.append("\(shown) shown") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Clipboard History")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Text(summary)
                        .settingsCaption()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .pointerCursor()
            }
            .padding()
            Divider()
            SearchField(placeholder: "Search…", text: $filterText, typeAhead: true)
                .padding(UIScale.pt(10))
            List(filtered) { entry in
                row(entry)
            }
            .listStyle(.inset)
        }
        .frame(width: UIScale.pt(480), height: UIScale.pt(520))
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
        entries = ClipboardActions.arrange(ClipboardRepository.loadEntries())
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            ClipboardThumbnailView(entry: entry, maxHeight: entry.kind == .text ? 18 : 40) {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(18))
            }
            .frame(minWidth: UIScale.pt(18))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                if entry.kind != .image {
                    Text(entry.displayPreview).lineLimit(2)
                }
                HStack(spacing: UIScale.pt(4)) {
                    Text(entry.sourceApp ?? "Unknown")
                    Text("·")
                    Text(entry.createdAt.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text(Self.byteCountFormatter.string(fromByteCount: Int64(entry.size)))
                }
                .settingsCaption()
            }
            Spacer()
            if copiedID == entry.id {
                Text("Copied").settingsCaption()
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
                    .foregroundStyle(entry.pinned ? themeColor(themeName) : .secondary)
            }
            .buttonStyle(.plain).pointerCursor()
            Button(role: .destructive) {
                delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).pointerCursor()
        }
        .padding(.vertical, UIScale.pt(4))
    }

    private func icon(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .file: return "doc"
        case .richText, .html: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .document: return "doc.text"
        case .media: return "play.rectangle"
        case .data: return "externaldrive"
        }
    }

    private func copy(_ entry: ClipboardEntry) {
        let plain = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
        apply { try ClipboardActions.copy(entry, asPlainText: plain) }
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private func togglePin(_ entry: ClipboardEntry) {
        apply { try ClipboardActions.togglePin(ids: [entry.id]) }
    }

    private func delete(_ entry: ClipboardEntry) {
        apply { try ClipboardActions.delete(ids: [entry.id]) }
    }

    private func apply(_ action: () throws -> ClipboardActions.Outcome) {
        guard let outcome = try? action(), outcome.changed > 0 else { return }
        entries = ClipboardActions.arrange(outcome.entries)
        IPC.post(IPC.Name.clipboardChanged)
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
