import AppKit
import EdithKit
import SwiftUI

struct BifrostPanelView: View {
    var store: BifrostStore
    var onDismiss: () -> Void
    var onRowsChanged: (Int) -> Void

    @State private var model: BifrostPanelModel
    @FocusState private var searchFocused: Bool

    init(
        store: BifrostStore, onDismiss: @escaping () -> Void,
        onRowsChanged: @escaping (Int) -> Void = { _ in }
    ) {
        self.store = store
        self.onDismiss = onDismiss
        self.onRowsChanged = onRowsChanged
        _model = State(initialValue: BifrostPanelModel(resolve: { store.results(for: $0) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !model.results.isEmpty {
                Divider().opacity(0.4)
                resultList
            }
        }
        .frame(width: BifrostPanel.width)
        .onAppear {
            searchFocused = true
            onRowsChanged(model.results.count)
        }
        .onChange(of: model.results.count) { _, count in onRowsChanged(count) }
        .onChange(of: store.revision) { _, _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: BifrostPanel.willShow)) { note in
            let prefill = note.userInfo?[BifrostPanel.prefillKey] as? String ?? ""
            model.reset(query: prefill)
            searchFocused = true
            onRowsChanged(model.results.count)
        }
        .onReceive(NotificationCenter.default.publisher(for: BifrostPanel.didHide)) { _ in
            model.reset()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "rainbow")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
            TextField(
                "Search apps, do sums, convert units",
                text: Binding(get: { model.query }, set: { model.setQuery($0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .regular))
            .lineLimit(1)
            .disableAutocorrection(true)
            .focused($searchFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                model.moveSelection(delta: press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onKeyPress(.escape) {
                onDismiss()
                return .handled
            }
            .onKeyPress(.return) {
                activate(model.selected)
                return .handled
            }
            if store.isIndexing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: BifrostPanel.headerHeight)
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(model.results) { result in
                BifrostResultRow(
                    result: result, isSelected: result.id == model.selectedID
                )
                .contentShape(Rectangle())
                .onTapGesture { activate(result) }
                .onHover { hovering in
                    if hovering { model.select(result.id) }
                }
            }
        }
    }

    private func activate(_ result: BifrostResult?) {
        guard let result else { return }
        onDismiss()
        store.run(result)
    }
}

struct BifrostResultRow: View {
    let result: BifrostResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(result.accessoryText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(height: BifrostPanel.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.22 : 0))
                .padding(.horizontal, 8)
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let iconPath = result.iconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: result.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(.tint)
        }
    }
}
