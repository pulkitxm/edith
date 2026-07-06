import EdithKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    var onDismiss: () -> Void
    var onHeightChange: (CGFloat) -> Void

    @State private var filterText = ""
    @State private var selectedID: String?
    @State private var keyboardScrollTick = 0
    @FocusState private var searchFocused: Bool
    @AppStorage("clipboardShowFooter", store: SharedDefaults.store) private var showFooter = true
    @AppStorage("clipboardPinTo", store: SharedDefaults.store) private var pinTo = "top"

    private static let headerHeight: CGFloat = 33
    private static let rowHeight: CGFloat = 24
    private static let imageRowHeight: CGFloat = 48
    private static let footerHeight: CGFloat = 55
    private static let bottomPadding: CGFloat = 5

    static func estimatedHeight(entries: [ClipboardEntry]) -> CGFloat {
        height(for: entries, showFooter: footerEnabled)
    }

    private static var footerEnabled: Bool {
        SharedDefaults.store.object(forKey: "clipboardShowFooter") as? Bool ?? true
    }

    private static func rowHeight(for entry: ClipboardEntry) -> CGFloat {
        entry.kind == .image || entry.kind == .file ? imageRowHeight : rowHeight
    }

    private static func height(for entries: [ClipboardEntry], showFooter: Bool) -> CGFloat {
        let rows = entries.isEmpty ? rowHeight : entries.reduce(0) { $0 + rowHeight(for: $1) }
        return headerHeight + rows + (showFooter ? footerHeight : 0) + bottomPadding
    }

    private var pinToTop: Bool { pinTo != "bottom" }

    private var visible: [ClipboardEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = store.entries.filter { entry in
            query.isEmpty
                || (entry.preview?.lowercased().contains(query) ?? false)
                || (entry.sourceApp?.lowercased().contains(query) ?? false)
        }
        let pinned = matched.filter(\.pinned).sorted { $0.createdAt > $1.createdAt }
        let unpinned = matched.filter { !$0.pinned }.sorted { $0.createdAt > $1.createdAt }
        return pinToTop ? pinned + unpinned : unpinned + pinned
    }

    private var digitShortcuts: [String: Int] {
        let unpinned = visible.filter { !$0.pinned }.prefix(9)
        return Dictionary(
            uniqueKeysWithValues: unpinned.enumerated().map { ($1.id, $0 + 1) })
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            list
            if showFooter { footer }
        }
        .padding(.bottom, Self.bottomPadding)
        .frame(width: ClipboardPanel.width)
        .onAppear {
            searchFocused = true
            selectedID = visible.first?.id
            reportHeight()
        }
        .onChange(of: filterText) { _, _ in
            selectedID = visible.first?.id
            keyboardScrollTick += 1
            reportHeight()
        }
        .onChange(of: store.entries) { _, _ in reportHeight() }
        .onChange(of: showFooter) { _, _ in reportHeight() }
    }

    private var searchField: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .resizable()
                    .frame(width: 11, height: 11)
                    .padding(.leading, 5)
                    .opacity(0.8)
                TextField("Search", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 4)
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
                        activate(selectedEntry, plainText: press.modifiers.contains(.option))
                        return .handled
                    }
                    .onKeyPress { press in handle(press) }
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .resizable()
                            .frame(width: 11, height: 11)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(.trailing, 5)
                }
            }
        }
        .frame(height: 23)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                if visible.isEmpty {
                    Text(filterText.isEmpty ? "Clipboard history is empty" : "No matches")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: Self.rowHeight)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(visible) { entry in
                        row(entry)
                            .id(entry.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        selectedID == entry.id
                                            ? Color.accentColor : Color.clear)
                            )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .padding(.horizontal, 5)
            .onChange(of: keyboardScrollTick) { _, _ in
                guard let selectedID else { return }
                proxy.scrollTo(selectedID)
            }
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let selected = selectedID == entry.id
        return HStack(spacing: 6) {
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            rowContent(entry)
            Spacer(minLength: 8)
            if let digit = digitShortcuts[entry.id] {
                Text("⌘\(digit)")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight(for: entry))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selectedID = entry.id }
        }
        .onTapGesture { activate(entry, plainText: false) }
    }

    @ViewBuilder private func rowContent(_ entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .image, .file:
            ClipboardThumbnailView(entry: entry, maxHeight: 40) {
                rowTitle(entry)
            }
        default:
            rowTitle(entry)
        }
    }

    private func rowTitle(_ entry: ClipboardEntry) -> some View {
        Text(title(entry))
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            footerRow("Clear", shortcut: "⌥⌘⌫") { clear() }
            footerRow("Preferences…", shortcut: "⌘,") { openPreferences() }
        }
        .padding(.horizontal, 5)
    }

    private func footerRow(
        _ label: String, shortcut: String, action: @escaping () -> Void
    ) -> some View {
        FooterRow(label: label, shortcut: shortcut, action: action)
    }

    private func title(_ entry: ClipboardEntry) -> String {
        (entry.preview ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var selectedEntry: ClipboardEntry? {
        visible.first { $0.id == selectedID }
    }

    private func move(_ delta: Int) {
        let items = visible
        guard !items.isEmpty else { return }
        let index = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? -delta
        let next = min(max(index + delta, 0), items.count - 1)
        selectedID = items[next].id
        keyboardScrollTick += 1
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command),
            let digit = press.key.character.wholeNumberValue, (1...9).contains(digit),
            let id = digitShortcuts.first(where: { $0.value == digit })?.key,
            let entry = visible.first(where: { $0.id == id })
        {
            activate(entry, plainText: press.modifiers.contains(.option))
            return .handled
        }
        if press.key == .delete {
            if press.modifiers.contains([.option, .command]) {
                clear()
                return .handled
            }
            if press.modifiers.contains(.option) {
                deleteSelected()
                return .handled
            }
        }
        if press.modifiers.contains(.option), press.key.character == "p",
            let entry = selectedEntry
        {
            store.togglePin(entry.id)
            return .handled
        }
        if press.modifiers.contains(.command), press.key.character == "," {
            openPreferences()
            return .handled
        }
        return .ignored
    }

    private func activate(_ entry: ClipboardEntry?, plainText: Bool) {
        guard let entry else { return }
        onDismiss()
        store.activate(entry, forcePlainText: plainText)
    }

    private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        let items = visible
        let index = items.firstIndex { $0.id == entry.id } ?? 0
        store.delete(entry.id)
        let remaining = visible
        if remaining.isEmpty {
            selectedID = nil
        } else {
            selectedID = remaining[min(index, remaining.count - 1)].id
        }
        reportHeight()
    }

    private func clear() {
        store.clear()
        selectedID = visible.first?.id
        reportHeight()
    }

    private func openPreferences() {
        SharedDefaults.store.set("settings", forKey: "mainWindowSection")
        SharedDefaults.store.set("clipboard", forKey: "settingsSection")
        MainApp.openDashboard()
        onDismiss()
    }

    private func reportHeight() {
        let sizingEntries = filterText.isEmpty ? visible : store.entries
        onHeightChange(Self.height(for: sizingEntries, showFooter: showFooter))
    }
}

private struct FooterRow: View {
    let label: String
    let shortcut: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text(shortcut)
                .font(.system(size: 11))
                .foregroundStyle(hovered ? Color.white.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 21)
        .foregroundStyle(hovered ? Color.white : Color.primary)
        .background(
            hovered ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}
