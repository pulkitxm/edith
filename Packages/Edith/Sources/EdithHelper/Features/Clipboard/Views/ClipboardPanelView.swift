import Combine
import EdithKit
import SwiftUI

struct ClipboardPanelView: View {
    var store: ClipboardStore
    var onDismiss: () -> Void
    var onHeightChange: (CGFloat) -> Void

    @State private var filterText = ""
    @State private var palette = ClipboardPalette()
    @State private var keyboardScrollTick = 0
    @State private var renderLimit = ClipboardPanelView.pageSize
    @State private var lastMouse = NSEvent.mouseLocation
    @State private var pendingClearPlan: ClipboardClearPlan?
    @State private var showingClearConfirmation = false
    @FocusState private var searchFocused: Bool
    @AppStorage(AppStorageKeys.Clipboard.showFooter, store: SharedDefaults.store) private
        var showFooter = true
    @AppStorage(AppStorageKeys.Clipboard.pinTo, store: SharedDefaults.store) private var pinTo =
        "top"
    @AppStorage(AppStorageKeys.Clipboard.capturePaused, store: SharedDefaults.store) private
        var capturePaused = false
    @AppStorage(AppStorageKeys.Clipboard.autoPaste, store: SharedDefaults.store) private
        var autoPaste = true
    @AppStorage(AppStorageKeys.Permissions.accessibilityGranted, store: SharedDefaults.store)
    private var accessibilityGranted = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    static let pageSize = 80

    static var footerEnabled: Bool {
        SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.showFooter) as? Bool ?? true
    }

    private var pinToTop: Bool { pinTo != "bottom" }
    private var showsChips: Bool { palette.categories.count > 1 }
    private var pastesOnPick: Bool { autoPaste && accessibilityGranted }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsChips { chips }
            Divider().opacity(0.5)
            list
            if showFooter {
                Divider().opacity(0.5)
                footer
            }
        }
        .frame(width: ClipboardPanelLayout.width)
        .onAppear { resetForShow() }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardPanel.willShow)) { _ in
            resetForShow()
        }
        .onChange(of: filterText) { _, text in
            palette.search(text)
            renderLimit = Self.pageSize
            keyboardScrollTick += 1
        }
        .onChange(of: store.revision) { _, _ in
            palette.replace(store.entries)
            reportHeight()
        }
        .onChange(of: pinTo) { _, _ in
            palette.setPinToTop(pinToTop)
            reportHeight()
        }
        .onChange(of: showFooter) { _, _ in reportHeight() }
        .confirmationDialog(
            pendingClearPlan?.confirmationTitle ?? "Clear clipboard history?",
            isPresented: $showingClearConfirmation,
            presenting: pendingClearPlan
        ) { plan in
            Button("Clear", role: .destructive) { store.clear(plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.confirmationMessage)
        }
        .alert(
            "Clipboard update failed",
            isPresented: Binding(
                get: { store.mutationError != nil },
                set: { if !$0 { store.dismissMutationError() } })
        ) {
            Button("OK") { store.dismissMutationError() }
        } message: {
            Text(store.mutationError ?? "The clipboard history could not be updated.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Type to search…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1)
                .disableAutocorrection(true)
                .focused($searchFocused)
                .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel("Clear search")
            }
            if let error = store.captureError ?? store.refreshError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Clipboard synchronization is retrying. \(error)")
                    .accessibilityLabel("Clipboard synchronization is retrying")
            }
            if capturePaused {
                Button {
                    store.setCapturePaused(false)
                } label: {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.edith(.borderless))
                .help("Capture is paused. Click to resume.")
            }
            Text(palette.countLabel)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            menu
        }
        .padding(.horizontal, 14)
        .frame(height: ClipboardPanelLayout.headerHeight)
    }

    private var menu: some View {
        Menu {
            Button(capturePaused ? "Resume Capture" : "Pause Capture") {
                store.setCapturePaused(!capturePaused)
            }
            Button("Clear Unpinned…") { requestClear() }
            Divider()
            Button("Settings…") { openPreferences() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Clipboard options")
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil)
                ForEach(palette.categories) { chip($0) }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: ClipboardPanelLayout.chipsHeight)
    }

    private func chip(_ category: ClipboardCategory?) -> some View {
        let active = palette.category == category
        return Button {
            palette.choose(category)
            renderLimit = Self.pageSize
            keyboardScrollTick += 1
        } label: {
            Text(category?.title ?? "All")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    Capsule().fill(
                        active ? themeColor(themeName) : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(active ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                if palette.rows.isEmpty {
                    emptyState
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(palette.sections(limit: renderLimit)) { section in
                        sectionHeader(section.title)
                        ForEach(section.entries) { entry in
                            row(entry)
                                .id(entry.id)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(
                                            palette.selectedID == entry.id
                                                ? themeColor(themeName) : Color.clear
                                        )
                                        .padding(.horizontal, 6)
                                )
                        }
                    }
                    if renderLimit < palette.rows.count {
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
            .environment(\.defaultMinListRowHeight, 1)
            .padding(.vertical, ClipboardPanelLayout.listPadding / 2)
            .onChange(of: keyboardScrollTick) { _, _ in
                guard let selectedID = palette.selectedID else { return }
                proxy.scrollTo(selectedID)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(
                maxWidth: .infinity, minHeight: ClipboardPanelLayout.sectionHeaderHeight,
                maxHeight: ClipboardPanelLayout.sectionHeaderHeight, alignment: .bottomLeading
            )
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(emptyTitle)
                .font(.system(size: 13, weight: .medium))
            Text(emptySubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ClipboardPanelLayout.emptyHeight)
    }

    private var emptyTitle: String {
        if palette.isFiltered { return "No matches" }
        return capturePaused ? "Capture is paused" : "Your copy stack is empty"
    }

    private var emptySubtitle: String {
        if palette.isFiltered { return "Try another word or category." }
        if capturePaused { return "Resume capture to start collecting copies again." }
        return "Copy anything and it lands here. \(ClipboardHotKey.label) opens it from any app."
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let selected = palette.selectedID == entry.id
        let category = palette.category(of: entry)
        let secondary = selected ? Color.white.opacity(0.75) : Color.secondary
        return Button {
            activate(entry, plainText: false)
        } label: {
            HStack(spacing: 10) {
                leading(entry, category: category, selected: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry))
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
                if let digit = palette.shortcut(for: entry.id) {
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
        .accessibilityLabel("\(category.title): \(title(entry))")
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let location = NSEvent.mouseLocation
            guard location != lastMouse else { return }
            lastMouse = location
            palette.select(entry.id)
        }
    }

    @ViewBuilder private func leading(
        _ entry: ClipboardEntry, category: ClipboardCategory, selected: Bool
    ) -> some View {
        let side: CGFloat = entry.kind == .image ? 44 : 28
        Group {
            switch category {
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
                    symbol(category, selected: selected)
                }
            case .image, .file:
                ClipboardThumbnailView(entry: entry, maxHeight: side) {
                    symbol(category, selected: selected)
                }
            default:
                symbol(category, selected: selected)
            }
        }
        .frame(width: side, height: side)
    }

    private func symbol(_ category: ClipboardCategory, selected: Bool) -> some View {
        Image(systemName: category.symbol)
            .font(.system(size: 14))
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(keys: "↑↓", label: "Navigate")
            if showsChips { KeyHint(keys: "←→", label: "Category") }
            KeyHint(keys: "↩", label: pastesOnPick ? "Paste" : "Copy")
            KeyHint(keys: "⌘P", label: "Pin")
            KeyHint(keys: "⌫", label: "Delete")
            Spacer(minLength: 0)
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 14)
        .frame(height: ClipboardPanelLayout.footerHeight)
    }

    private func title(_ entry: ClipboardEntry) -> String {
        entry.displayPreview
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func resetForShow() {
        lastMouse = NSEvent.mouseLocation
        palette.setPinToTop(pinToTop)
        palette.replace(store.entries)
        palette.reset()
        filterText = ""
        renderLimit = Self.pageSize
        keyboardScrollTick += 1
        reportHeight()
        DispatchQueue.main.async { searchFocused = true }
    }

    private func extendPage() {
        guard renderLimit < palette.rows.count else { return }
        renderLimit = min(palette.rows.count, renderLimit + Self.pageSize)
    }

    private func revealSelection() {
        if let index = palette.selectedIndex, index >= renderLimit {
            renderLimit = min(palette.rows.count, index + Self.pageSize)
        }
        keyboardScrollTick += 1
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard
            let command = ClipboardPaletteKeymap.command(
                key: press.key, modifiers: press.modifiers, queryIsEmpty: filterText.isEmpty)
        else { return .ignored }
        perform(command)
        return .handled
    }

    private func perform(_ command: ClipboardPaletteCommand) {
        switch command {
        case .move(let delta):
            palette.move(by: delta)
            revealSelection()
        case .jump(let top):
            palette.jump(toTop: top)
            revealSelection()
        case .cycleCategory(let delta):
            palette.cycleCategory(by: delta)
            renderLimit = Self.pageSize
            keyboardScrollTick += 1
        case .paste(let plainText):
            activate(palette.selected, plainText: plainText)
        case .quickPaste(let digit, let plainText):
            activate(palette.entry(forShortcut: digit), plainText: plainText)
        case .togglePin:
            guard let id = palette.selectedID else { return }
            store.togglePin(id)
            palette.replace(store.entries)
            revealSelection()
        case .delete:
            guard let id = palette.selectedID else { return }
            store.delete(id)
            palette.replace(store.entries)
            revealSelection()
        case .clearUnpinned:
            requestClear()
        case .clearSearch:
            filterText = ""
        case .dismiss:
            onDismiss()
        case .preferences:
            openPreferences()
        }
    }

    private func activate(_ entry: ClipboardEntry?, plainText: Bool) {
        guard let entry else { return }
        onDismiss()
        store.activate(entry, forcePlainText: plainText)
    }

    private func requestClear() {
        let plan = ClipboardOperationExecution.clearPlan(entries: store.entries, keepPinned: true)
        guard plan.removed > 0 else { return }
        pendingClearPlan = plan
        showingClearConfirmation = true
    }

    private func openPreferences() {
        SharedDefaults.store.set("settings", forKey: AppStorageKeys.General.mainWindowSection)
        SharedDefaults.store.set("clipboard", forKey: AppStorageKeys.General.settingsSection)
        MainApp.openDashboard()
        onDismiss()
    }

    private func reportHeight() {
        onHeightChange(
            ClipboardPanelLayout.estimatedHeight(
                for: store.entries, pinToTop: pinToTop, showsFooter: showFooter))
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minWidth: 20)
                .frame(height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.16)))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
