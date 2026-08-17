import Combine
import EdithKit
import SwiftUI

struct ClipboardPanelView: View {
    var store: ClipboardStore
    var onDismiss: () -> Void
    var onHeightChange: (CGFloat) -> Void

    @State private var filterText = ""
    @State private var selectedID: String?
    @State private var keyboardScrollTick = 0
    @State private var arranged: [ClipboardEntry] = []
    @State private var visible: [ClipboardEntry] = []
    @State private var renderLimit = ClipboardPanelView.pageSize
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var lastMouse = NSEvent.mouseLocation
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var listHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @AppStorage(AppStorageKeys.Clipboard.showFooter, store: SharedDefaults.store) private
        var showFooter = true
    @AppStorage(AppStorageKeys.Clipboard.pinTo, store: SharedDefaults.store) private var pinTo =
        "top"
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    static let pageSize = 80

    static func jumpTargetIndex(
        itemCount: Int, top: Bool, shownEdgeIndex: Int?, renderedCount: Int
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        if top { return 0 }
        guard renderedCount > 0 else { return nil }
        if let shownEdgeIndex, (0..<min(renderedCount, itemCount)).contains(shownEdgeIndex) {
            return shownEdgeIndex
        }
        return min(renderedCount, itemCount) - 1
    }

    private static let headerHeight: CGFloat = 33
    private static let rowHeight: CGFloat = 24
    private static let imageRowHeight: CGFloat = 48
    private static let footerHeight: CGFloat = 55
    private static let bottomPadding: CGFloat = 5

    static func estimatedHeight(entries: [ClipboardEntry]) -> CGFloat {
        height(for: entries, showFooter: footerEnabled)
    }

    private static var footerEnabled: Bool {
        SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.showFooter) as? Bool ?? true
    }

    private static func rowHeight(for entry: ClipboardEntry) -> CGFloat {
        entry.kind == .image || entry.kind == .file ? imageRowHeight : rowHeight
    }

    private static func height(for entries: [ClipboardEntry], showFooter: Bool) -> CGFloat {
        let chrome = headerHeight + (showFooter ? footerHeight : 0) + bottomPadding
        guard !entries.isEmpty else { return chrome + rowHeight }
        var rows: CGFloat = 0
        for entry in entries {
            rows += rowHeight(for: entry)
            if chrome + rows >= ClipboardPanel.maxHeight { break }
        }
        return chrome + rows
    }

    private var pinToTop: Bool { pinTo != "bottom" }

    private nonisolated static func arrange(
        _ entries: [ClipboardEntry], query: String, pinToTop: Bool
    ) -> [ClipboardEntry] {
        ClipboardActions.arrange(entries, query: query, pinToTop: pinToTop)
    }

    private nonisolated static func search(
        _ entries: [ClipboardEntry], query: String, pinToTop: Bool
    ) async -> [ClipboardEntry] {
        arrange(entries, query: query, pinToTop: pinToTop)
    }

    private func adoptArranged(_ result: [ClipboardEntry], selectFirst: Bool) {
        arranged = result
        syncVisible()
        if selectFirst { selectFirstRow() }
        reportHeight()
    }

    private func syncVisible() {
        visible = Array(arranged.prefix(renderLimit))
    }

    private func ensureRendered(upTo index: Int) {
        guard index >= renderLimit else { return }
        renderLimit = min(arranged.count, index + Self.pageSize)
        syncVisible()
    }

    private func extendPage() {
        guard renderLimit < arranged.count else { return }
        renderLimit = min(arranged.count, renderLimit + Self.pageSize)
        syncVisible()
    }

    private func refreshVisible(selectFirst: Bool = false, resetLimit: Bool = false) {
        searchTask?.cancel()
        if resetLimit { renderLimit = Self.pageSize }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            searching = false
            adoptArranged(
                Self.arrange(store.entries, query: query, pinToTop: pinToTop),
                selectFirst: selectFirst)
            return
        }
        searching = true
        let entries = store.entries
        let pinTop = pinToTop
        searchTask = Task {
            let result = await Self.search(entries, query: query, pinToTop: pinTop)
            guard !Task.isCancelled else { return }
            searching = false
            adoptArranged(result, selectFirst: selectFirst)
        }
    }

    private func resetForShow() {
        lastMouse = NSEvent.mouseLocation
        searchTask?.cancel()
        searching = false
        filterText = ""
        renderLimit = Self.pageSize
        refreshVisible(selectFirst: true)
        DispatchQueue.main.async { searchFocused = true }
    }

    private func selectFirstRow() {
        selectedID = visible.first?.id
        keyboardScrollTick += 1
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
        .onAppear { resetForShow() }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardPanel.willShow)) { _ in
            resetForShow()
        }
        .onChange(of: filterText) { _, _ in
            refreshVisible(selectFirst: true, resetLimit: true)
        }
        .onChange(of: store.revision) { _, _ in refreshVisible() }
        .onChange(of: pinTo) { _, _ in refreshVisible() }
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
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        let up = press.key == .upArrow
                        if press.modifiers.contains(.command) {
                            jumpToEdge(top: up)
                        } else {
                            move(up ? -1 : 1)
                        }
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
                if searching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                        .padding(.trailing, 4)
                }
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
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RowFramesKey.self,
                                        value: [entry.id: geo.frame(in: .named("clipboardList"))])
                                }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        selectedID == entry.id
                                            ? themeColor(themeName) : Color.clear)
                            )
                    }
                    if visible.count < arranged.count {
                        Color.clear
                            .frame(height: 1)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onAppear { extendPage() }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .padding(.horizontal, 5)
            .coordinateSpace(name: "clipboardList")
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { listHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in listHeight = height }
                }
            )
            .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
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
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let location = NSEvent.mouseLocation
            guard location != lastMouse else { return }
            lastMouse = location
            selectedID = entry.id
        }
        .onTapGesture { activate(entry, plainText: false) }
    }

    @ViewBuilder private func rowContent(_ entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .image:
            ClipboardThumbnailView(entry: entry, maxHeight: 40) {
                rowTitle(entry)
            }
        case .file:
            HStack(spacing: 6) {
                ClipboardThumbnailView(entry: entry, maxHeight: 40) {
                    Image(systemName: "doc")
                }
                .frame(width: 40)
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
            .truncationMode(.tail)
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
        entry.displayPreview
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var selectedEntry: ClipboardEntry? {
        arranged.first { $0.id == selectedID }
    }

    private func move(_ delta: Int) {
        let items = arranged
        guard !items.isEmpty else { return }
        let index = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? -delta
        let next: Int
        if delta < 0, index == 0 {
            next = edgeShownIndex(in: items, bottom: true) ?? items.count - 1
        } else if delta > 0, index == items.count - 1 {
            next = edgeShownIndex(in: items, bottom: false) ?? 0
        } else {
            next = min(max(index + delta, 0), items.count - 1)
        }
        ensureRendered(upTo: next)
        selectedID = items[next].id
        keyboardScrollTick += 1
    }

    private func jumpToEdge(top: Bool) {
        let items = arranged
        let shownEdgeIndex = top ? nil : edgeShownIndex(in: items, bottom: true)
        guard
            let index = Self.jumpTargetIndex(
                itemCount: items.count, top: top, shownEdgeIndex: shownEdgeIndex,
                renderedCount: visible.count)
        else { return }
        selectedID = items[index].id
        keyboardScrollTick += 1
    }

    private func edgeShownIndex(in items: [ClipboardEntry], bottom: Bool) -> Int? {
        let shown = rowFrames.filter { $0.value.minY >= -1 && $0.value.maxY <= listHeight + 1 }
        let edge =
            bottom
            ? shown.max { $0.value.minY < $1.value.minY }
            : shown.min { $0.value.minY < $1.value.minY }
        guard let id = edge?.key else { return nil }
        return items.firstIndex { $0.id == id }
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
        let index = arranged.firstIndex { $0.id == entry.id } ?? 0
        arranged.removeAll { $0.id == entry.id }
        syncVisible()
        store.delete(entry.id)
        if arranged.isEmpty {
            selectedID = nil
        } else {
            let nextIndex = min(index, arranged.count - 1)
            ensureRendered(upTo: nextIndex)
            selectedID = arranged[nextIndex].id
        }
        reportHeight()
    }

    private func clear() {
        store.clear()
        arranged = []
        visible = []
        selectedID = nil
        reportHeight()
    }

    private func openPreferences() {
        SharedDefaults.store.set("settings", forKey: AppStorageKeys.General.mainWindowSection)
        SharedDefaults.store.set("clipboard", forKey: "settingsSection")
        MainApp.openDashboard()
        onDismiss()
    }

    private func reportHeight() {
        let sizingEntries = filterText.isEmpty ? arranged : store.entries
        onHeightChange(Self.height(for: sizingEntries, showFooter: showFooter))
    }
}

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct FooterRow: View {
    let label: String
    let shortcut: String
    let action: () -> Void

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
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
            hovered ? themeColor(themeName) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}
