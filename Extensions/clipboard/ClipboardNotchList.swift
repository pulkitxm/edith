import EdithExtensionUI
import SwiftUI

struct ClipboardNotchList: View {
    let history: ClipboardHistoryModel
    var available = true

    private var sortedEntries: [ClipboardEntry] {
        history.entries.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
    }

    var body: some View {
        Group {
            if available {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sortedEntries.prefix(30)) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 2)
                }
            } else {
                Text("Clipboard history is off")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .pageTask(cancel: { history.stop() }) { history.start() }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                history.copy(entry)
            } label: {
                Text(entry.displayPreview)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            Button {
                history.mutate(.init(entry.pinned ? .unpin : .pin, ids: [entry.id]))
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(entry.pinned ? 0.9 : 0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(entry.pinned ? "Unpin" : "Pin")
            Button {
                history.mutate(.init(.delete, ids: [entry.id]))
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("Delete")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
