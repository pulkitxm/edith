import AppKit
import EdithKit
import SwiftUI

struct EmojiSection: Identifiable, Hashable {
    let id: String
    let title: String
    let symbolName: String
    let emoji: [Emoji]
}

struct EmojiPanelView: View {
    var store: EmojiStore
    var onDismiss: () -> Void
    var onCellAppear: (EmojiPanelCell.ID) -> Void

    @State private var model: EmojiPanelModel
    @State private var scrollTick = 0
    @State private var pendingSectionScroll: String?
    @FocusState private var searchFocused: Bool
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    static let columns = 9
    static let cellSize: CGFloat = 34
    static let cellSpacing: CGFloat = 4
    static let frequentSectionID = "frequent"
    static let resultsSectionID = "results"

    init(
        store: EmojiStore, onDismiss: @escaping () -> Void,
        onCellAppear: @escaping (EmojiPanelCell.ID) -> Void = { _ in }
    ) {
        self.store = store
        self.onDismiss = onDismiss
        self.onCellAppear = onCellAppear
        _model = State(
            initialValue: EmojiPanelModel(
                catalog: store.catalog, frequent: store.frequent, search: store.search))
    }

    static func sections(catalog: EmojiCatalog, frequent: [Emoji], query: String) -> [EmojiSection]
    {
        let normalized = EmojiSearch.normalize(query)
        guard normalized.isEmpty else {
            let matches = EmojiSearch.results(in: catalog.emoji, query: normalized)
            guard !matches.isEmpty else { return [] }
            return [
                EmojiSection(
                    id: resultsSectionID, title: "Results", symbolName: "magnifyingglass",
                    emoji: matches)
            ]
        }
        return EmojiPanelModel.baseSections(catalog: catalog, frequent: frequent)
    }

    static func nextSelection(from index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            grid
            Divider().opacity(0.5)
            preview
            categoryBar
        }
        .frame(width: EmojiPanel.width, height: EmojiPanel.height)
        .onAppear { resetForShow() }
        .onReceive(NotificationCenter.default.publisher(for: EmojiPanel.willShow)) { _ in
            resetForShow()
        }
        .onReceive(NotificationCenter.default.publisher(for: EmojiPanel.didHide)) { _ in
            model.cancelSearch()
        }
        .onChange(of: store.revision) { _, _ in model.updateFrequent(store.frequent) }
        .onDisappear { model.cancelSearch() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            searchField
            tonePicker
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                TextField(
                    "Search emoji",
                    text: Binding(get: { model.query }, set: { model.setQuery($0) })
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1)
                .disableAutocorrection(true)
                .focused($searchFocused)
                .padding(.horizontal, 4)
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    handleArrow(press)
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    activate(model.selected, copyOnly: press.modifiers.contains(.option))
                    return .handled
                }
                .onKeyPress { press in handle(press) }
                if !model.query.isEmpty {
                    Button {
                        model.setQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .resizable()
                            .frame(width: 11, height: 11)
                    }
                    .buttonStyle(.edith(.borderless))
                    .padding(.trailing, 5)
                }
            }
        }
        .frame(height: 23)
    }

    private var tonePicker: some View {
        Menu {
            ForEach(EmojiSkinTone.allCases) { tone in
                Button {
                    store.skinTone = tone
                } label: {
                    Text("\(tone.sample)  \(tone.title)")
                }
            }
        } label: {
            Text(store.skinTone.sample)
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Default skin tone")
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    if model.renderedSections.isEmpty {
                        Text("No emoji match \u{201C}\(model.query)\u{201D}")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(model.renderedSections) { section in
                        Section {
                            sectionGrid(section)
                        } header: {
                            sectionHeader(section)
                        }
                        .id(section.id)
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: scrollTick) { _, _ in
                guard let selectedID = model.selectedID else { return }
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onChange(of: pendingSectionScroll) { _, target in
                guard let target else { return }
                pendingSectionScroll = nil
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .top) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionHeader(_ section: EmojiSection) -> some View {
        Text(section.title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
    }

    private func sectionGrid(_ section: EmojiSection) -> some View {
        LazyVStack(spacing: Self.cellSpacing) {
            ForEach(model.rows(for: section)) { row in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(row.cells) { cell in
                        emojiCell(cell)
                    }
                    ForEach(0..<(Self.columns - row.cells.count), id: \.self) { _ in
                        Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
                .onAppear {
                    if row.isRenderBoundary { model.extend(sectionID: row.sectionID) }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func emojiCell(_ cell: EmojiPanelCell) -> some View {
        let emoji = cell.emoji
        let character = store.character(for: emoji)
        let isSelected = model.selectedID == cell.id
        return Button {
            activate(emoji, copyOnly: false)
        } label: {
            Text(character)
                .font(.system(size: 22))
                .frame(width: Self.cellSize, height: Self.cellSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? themeColor(themeName).opacity(0.28) : Color.clear))
        }
        .buttonStyle(.edith(.borderless))
        .id(cell.id)
        .onAppear { onCellAppear(cell.id) }
        .help(emoji.name)
        .contextMenu { contextMenu(for: emoji) }
    }

    @ViewBuilder private func contextMenu(for emoji: Emoji) -> some View {
        Button("Copy \(store.character(for: emoji))") { store.copy(emoji) }
        if emoji.supportsSkinTones {
            Divider()
            ForEach(EmojiSkinTone.allCases) { tone in
                Button("Insert \(emoji.character(tone: tone))") {
                    onDismiss()
                    store.insert(emoji, tone: tone)
                }
            }
        }
        if store.frequentIDs.contains(emoji.id) {
            Divider()
            Button("Remove from frequently used") { store.forget(emoji.character) }
        }
    }

    private var preview: some View {
        HStack(spacing: 8) {
            if let emoji = model.selected {
                Text(store.character(for: emoji))
                    .font(.system(size: 20))
                Text(emoji.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Type to search, arrows to move, return to insert")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.selected?.supportsSkinTones == true {
                Text("\u{2325}\u{2318}1-5 tone")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 12)
    }

    private var categoryBar: some View {
        HStack(spacing: 0) {
            ForEach(model.sections) { section in
                Button {
                    pendingSectionScroll = model.revealSection(section.id)
                } label: {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
                .help(section.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .opacity(model.sections.count > 1 ? 1 : 0)
    }

    private func resetForShow() {
        model.reset(frequent: store.frequent)
        DispatchQueue.main.async { searchFocused = true }
    }

    private func handleArrow(_ press: KeyPress) -> KeyPress.Result {
        let delta: Int
        switch press.key {
        case .leftArrow: delta = -1
        case .rightArrow: delta = 1
        case .upArrow: delta = -Self.columns
        default: delta = Self.columns
        }
        _ = model.moveSelection(delta: delta)
        scrollTick += 1
        return .handled
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains([.option, .command]),
            let digit = press.key.character.wholeNumberValue, (1...5).contains(digit),
            let emoji = model.selected, emoji.supportsSkinTones,
            let tone = EmojiSkinTone(rawValue: digit)
        {
            activate(emoji, copyOnly: false, tone: tone)
            return .handled
        }
        if press.modifiers.contains(.command), press.key.character == "," {
            openPreferences()
            return .handled
        }
        return .ignored
    }

    private func activate(_ emoji: Emoji?, copyOnly: Bool, tone: EmojiSkinTone? = nil) {
        guard let emoji else { return }
        onDismiss()
        if copyOnly {
            store.copy(emoji, tone: tone)
        } else {
            store.insert(emoji, tone: tone)
        }
    }

    private func openPreferences() {
        SharedDefaults.store.set("settings", forKey: AppStorageKeys.General.mainWindowSection)
        SharedDefaults.store.set("emoji", forKey: AppStorageKeys.General.settingsSection)
        MainApp.openDashboard()
        onDismiss()
    }
}
