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

    private func summary(shown: Int) -> String {
        var parts = [entries.count == 1 ? "1 item" : "\(entries.count) items"]
        parts.append(
            Self.byteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }))
        )
        let pinned = entries.filter(\.pinned).count
        if pinned > 0 { parts.append("\(pinned) pinned") }
        if shown != entries.count { parts.append("\(shown) shown") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let filtered = ClipboardActions.arrange(entries, query: filterText)
        return VStack(spacing: UIScale.pt(0)) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Clipboard History")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Text(summary(shown: filtered.count))
                        .settingsCaption()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.edithDefault)
            }
            .padding(.horizontal, ClipboardHistoryRow.inset)
            .padding(.vertical, UIScale.pt(14))
            if let error = model.error {
                Text(error).settingsCaption().foregroundStyle(.red)
                    .padding(.horizontal, ClipboardHistoryRow.inset)
            }
            Divider()
            SearchField(placeholder: "Search…", text: $filterText, typeAhead: true)
                .padding(.horizontal, ClipboardHistoryRow.inset)
                .padding(.vertical, UIScale.pt(10))
            VirtualList(
                filtered, rowHeight: { _ in ClipboardHistoryRow.height }, header: { EmptyView() }
            ) { entry in
                ClipboardHistoryRow(entry: entry, model: model).id(entry.id)
            }
        }
        .frame(width: PresentationMetrics.width(480), height: PresentationMetrics.height(520))
        .pageTask(cancel: { model.stop() }) { model.start() }
    }

    fileprivate static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private struct ClipboardHistoryRow: View {
    @MainActor static var height: CGFloat { UIScale.pt(58) }
    @MainActor static var inset: CGFloat { UIScale.pt(14) }

    let entry: ClipboardEntry
    let model: ClipboardHistoryModel
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(10)) {
            ClipboardThumbnailView(
                entry: entry, maxHeight: entry.kind == .text ? 18 : 40, client: model.client
            ) {
                EdithIconView(icon)
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
                    Text(
                        ClipboardHistoryView.byteCountFormatter.string(
                            fromByteCount: Int64(entry.size)))
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
                EdithIconView(.copy)
            }
            .buttonStyle(.edith(.borderless))
            Button {
                model.mutate(.init(entry.pinned ? .unpin : .pin, ids: [entry.id]))
            } label: {
                EdithIconView(.pin, tone: entry.pinned ? .duotone : .muted)
                    .foregroundStyle(entry.pinned ? themeColor(themeName) : .secondary)
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel(entry.pinned ? "Unpin" : "Pin")
            Button(role: .destructive) {
                model.mutate(.init(.delete, ids: [entry.id]))
            } label: {
                EdithIconView(.trash)
            }
            .buttonStyle(.edith(.borderless))
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var icon: EdithIcon {
        switch entry.kind {
        case .image: return .photo
        case .file: return .doc
        case .richText, .html: return .docText
        case .text: return .textLines
        case .document: return .docText
        case .media: return .play
        case .data: return .drive
        }
    }
}
