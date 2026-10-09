import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Bindable var model: ClipboardHistoryModel
    @State private var filterText = ""
    private var entries: [ClipboardEntry] { model.entries }

    private var filtered: [ClipboardEntry] {
        ClipboardActions.arrange(entries, query: filterText)
    }

    private var summary: String {
        var parts = [entries.count == 1 ? "1 item" : "\(entries.count) items"]
        parts.append(
            Self.byteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }))
        )
        let pinned = entries.filter(\.pinned).count
        if pinned > 0 { parts.append("\(pinned) pinned") }
        let shown = filtered.count
        if shown != entries.count { parts.append("\(shown) shown") }
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
            }
            .padding()
            if let error = model.error {
                Text(error).settingsCaption().foregroundStyle(.red).padding(.horizontal)
            }
            Divider()
            SearchField(placeholder: "Search…", text: $filterText)
                .padding(UIScale.pt(10))
            List(filtered) { entry in
                row(entry)
            }
            .listStyle(.inset)
        }
        .frame(width: PresentationMetrics.width(480), height: PresentationMetrics.height(520))
        .pageTask(cancel: { model.stop() }) { model.start() }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            ClipboardThumbnailView(
                entry: entry, maxHeight: entry.kind == .text ? 18 : 40, client: model.client
            ) {
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
            if model.copiedID == entry.id {
                Text("Copied").settingsCaption()
            }
            Button {
                model.copy(entry)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.edith(.borderless))
            Button {
                model.mutate(.init(entry.pinned ? .unpin : .pin, ids: [entry.id]))
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.pinned ? themeColor(themeName) : .secondary)
            }
            .buttonStyle(.edith(.borderless))
            Button(role: .destructive) {
                model.mutate(.init(.delete, ids: [entry.id]))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.edith(.borderless))
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

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
