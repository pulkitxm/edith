import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

struct ClipboardPanelRowModel: Identifiable, Equatable {
    let entry: ClipboardEntry
    let category: ClipboardCategory
    let shortcut: Int?
    var id: String { entry.id }
}

struct ClipboardPanelSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [ClipboardPanelRowModel]

    static func build(_ palette: ClipboardPalette) -> [ClipboardPanelSection] {
        palette.sections().map { section in
            ClipboardPanelSection(
                id: section.id, title: section.title,
                rows: section.entries.map {
                    ClipboardPanelRowModel(
                        entry: $0, category: palette.category(of: $0),
                        shortcut: palette.shortcut(for: $0.id))
                })
        }
    }
}

@MainActor
@Observable
final class ClipboardPanelSelection {
    var id: String?
}

struct ClipboardPanelList: View, Equatable {
    let sections: [ClipboardPanelSection]
    let selection: ClipboardPanelSelection
    let themeName: String
    let client: ClipboardClient
    let activate: (ClipboardEntry) -> Void
    let hover: (String) -> Void

    nonisolated static func == (lhs: ClipboardPanelList, rhs: ClipboardPanelList) -> Bool {
        lhs.sections == rhs.sections && lhs.selection === rhs.selection
            && lhs.themeName == rhs.themeName
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(sections) { section in
                header(section.title)
                ForEach(section.rows) { model in
                    ClipboardPanelRow(
                        model: model, selection: selection, themeName: themeName, client: client,
                        activate: activate, hover: hover
                    )
                    .id(model.id)
                }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(
                maxWidth: .infinity, minHeight: ClipboardPanelLayout.sectionHeaderHeight,
                maxHeight: ClipboardPanelLayout.sectionHeaderHeight, alignment: .bottomLeading
            )
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ClipboardPanelRow: View {
    let model: ClipboardPanelRowModel
    let selection: ClipboardPanelSelection
    let themeName: String
    let client: ClipboardClient
    let activate: (ClipboardEntry) -> Void
    let hover: (String) -> Void

    var body: some View {
        let entry = model.entry
        let selected = selection.id == entry.id
        let secondary = selected ? Color.white.opacity(0.75) : Color.secondary
        Button {
            activate(entry)
        } label: {
            HStack(spacing: 10) {
                leading(selected: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(ClipboardTimeline.subtitle(for: entry))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(secondary)
                }
                Spacer(minLength: 8)
                if entry.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(secondary)
                        .accessibilityLabel("Pinned")
                }
                if let digit = model.shortcut {
                    Text("⌘\(digit)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: ClipboardPanelLayout.rowHeight(for: entry))
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? themeColor(themeName) : Color.clear)
                .padding(.horizontal, 6)
        )
        .accessibilityLabel("\(model.category.title): \(title)")
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            hover(entry.id)
        }
    }

    private var title: String {
        model.entry.displayPreview
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    @ViewBuilder private func leading(selected: Bool) -> some View {
        let entry = model.entry
        let side: CGFloat = entry.kind == .image ? 44 : 28
        Group {
            switch model.category {
            case .color:
                if let color = ClipboardColorValue(parsing: entry.preview ?? "") {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            Color(
                                .sRGB, red: color.red, green: color.green, blue: color.blue,
                                opacity: color.alpha)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15))
                        )
                        .frame(width: 22, height: 22)
                } else {
                    symbol(selected: selected)
                }
            case .image, .file:
                ClipboardThumbnailView(entry: entry, maxHeight: side, client: client) {
                    symbol(selected: selected)
                }
            default:
                symbol(selected: selected)
            }
        }
        .frame(width: side, height: side)
    }

    private func symbol(selected: Bool) -> some View {
        Image(systemName: model.category.symbol)
            .font(.system(size: 14))
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
    }
}
