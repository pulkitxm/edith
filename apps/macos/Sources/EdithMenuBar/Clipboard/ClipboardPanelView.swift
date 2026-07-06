import EdithKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    var onDismiss: () -> Void

    @State private var filterText = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipboardEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = store.entries.filter { entry in
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
            searchField
            Divider()
            list
            if let at = store.skippedOversizeAt, Date().timeIntervalSince(at) < 4 {
                Text("Skipped a copy over the size limit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(width: 360, height: 420)
        .onAppear {
            searchFocused = true
            selectedID = filtered.first?.id
        }
        .onChange(of: filterText) { _, _ in
            selectedID = filtered.first?.id
        }
    }

    private var searchField: some View {
        TextField("Search clipboard history", text: $filterText)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(10)
            .focused($searchFocused)
            .onKeyPress(.downArrow) {
                move(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                move(-1)
                return .handled
            }
            .onKeyPress(.escape) {
                onDismiss()
                return .handled
            }
            .onKeyPress(keys: [.return]) { press in
                activateSelected(plainText: press.modifiers.contains(.option))
                return .handled
            }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: entry.kind))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview ?? "")
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(entry.sourceApp ?? "Unknown")
                    Text("·")
                    Text(entry.createdAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                store.togglePin(entry.id)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            selectedID == entry.id ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = entry.id
            store.activate(entry)
            onDismiss()
        }
    }

    private func icon(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .file: return "doc"
        case .richText, .html: return "doc.richtext"
        case .text: return "doc.plaintext"
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = selectedID.flatMap { id in filtered.firstIndex { $0.id == id } } ?? -delta
        let next = min(max(index + delta, 0), filtered.count - 1)
        selectedID = filtered[next].id
    }

    private func activateSelected(plainText: Bool) {
        guard let id = selectedID, let entry = filtered.first(where: { $0.id == id }) else {
            return
        }
        store.activate(entry, forcePlainText: plainText)
        onDismiss()
    }
}
