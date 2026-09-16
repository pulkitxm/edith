import AppKit
import EdithKit
import SwiftUI

struct BifrostPanelView: View {
    var store: BifrostStore
    var onDismiss: () -> Void
    var onHeightChanged: (CGFloat) -> Void

    @State private var model: BifrostPanelModel
    @State private var lastMouse = NSEvent.mouseLocation
    @FocusState private var searchFocused: Bool

    init(
        store: BifrostStore, onDismiss: @escaping () -> Void,
        onHeightChanged: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.store = store
        self.onDismiss = onDismiss
        self.onHeightChanged = onHeightChanged
        _model = State(
            initialValue: BifrostPanelModel(resolve: { query in
                store.mode == .launcher ? store.results(for: query) : store.modeResults
            }))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.sections.isEmpty || store.mode != .launcher {
                Divider().opacity(0.25)
                content
                footer
            }
        }
        .frame(width: BifrostPanelMetrics.width, height: height, alignment: .top)
        .background(BifrostPanelMetrics.scrim)
        .edithGlass(in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .onAppear {
            searchFocused = true
            lastMouse = NSEvent.mouseLocation
            BifrostPanel.shared.shortcutHandler = { number in
                guard let result = model.result(atShortcut: number) else { return false }
                activate(result)
                return true
            }
            publishHeight()
        }
        .onDisappear { BifrostPanel.shared.shortcutHandler = nil }
        .onChange(of: height) { _, _ in publishHeight() }
        .onChange(of: store.revision) { _, _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: BifrostPanel.willShow)) { note in
            store.leaveMode()
            model.reset(query: note.userInfo?[BifrostPanel.prefillKey] as? String ?? "")
            searchFocused = true
            lastMouse = NSEvent.mouseLocation
            publishHeight()
        }
        .onReceive(NotificationCenter.default.publisher(for: BifrostPanel.didHide)) { _ in
            store.leaveMode()
            model.reset()
        }
    }

    private var height: CGFloat {
        store.mode == .launcher
            ? model.height
            : BifrostPanelMetrics.headerHeight + BifrostPanelMetrics.modeHeight
                + BifrostPanelMetrics.footerHeight
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BifrostPanelMetrics.cornerRadius, style: .continuous)
    }

    private func publishHeight() {
        onHeightChanged(height)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if store.mode == .launcher {
                Image(nsImage: Logo.header)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .opacity(0.9)
            } else {
                Button {
                    leaveMode()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.10)))
                }
                .buttonStyle(.edith(.borderless))
            }
            TextField(store.mode.placeholder, text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .lineLimit(1)
                .disableAutocorrection(true)
                .focused($searchFocused)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    model.moveSelection(delta: press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if store.mode == .launcher { onDismiss() } else { leaveMode() }
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    activate(model.selected, copyOnly: press.modifiers.contains(.option))
                    return .handled
                }
            if store.isIndexing || store.isLoadingMode {
                BifrostSkeletonPill()
            }
            if store.mode == .files {
                filterPicker(
                    title: store.target.title,
                    options: BifrostSearchTarget.allCases.map { ($0.title, $0) },
                    select: { store.select(target: $0, query: model.query) })
                filterPicker(
                    title: store.searchKind.title,
                    options: BifrostSearchKind.allCases.map { ($0.title, $0) },
                    select: { store.select(searchKind: $0, query: model.query) })
            }
            if store.mode != .launcher {
                scopePicker
            }
        }
        .padding(.horizontal, 16)
        .frame(height: BifrostPanelMetrics.headerHeight)
    }

    private var scopePicker: some View {
        Menu {
            ForEach(store.scopes) { scope in
                Button(scope.title) { store.select(scope: scope, query: model.query) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.scope.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func filterPicker<Option>(
        title: String, options: [(String, Option)], select: @escaping (Option) -> Void
    ) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.0) { select(option.1) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: { value in
                model.setQuery(value)
                if store.mode != .launcher { store.loadMode(query: value) }
                publishHeight()
            })
    }

    @ViewBuilder
    private var content: some View {
        if store.mode == .launcher {
            resultList.frame(height: model.listHeight)
        } else {
            HStack(spacing: 0) {
                resultList
                    .frame(
                        width: BifrostPanelMetrics.width * (1 - BifrostPanelMetrics.detailFraction))
                Divider().opacity(0.25)
                BifrostDetailPane(detail: model.selected?.detail)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: BifrostPanelMetrics.modeHeight)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.results) { result in
                                row(result)
                            }
                        } header: {
                            BifrostSectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.vertical, BifrostPanelMetrics.listPadding / 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func row(_ result: BifrostResult) -> some View {
        Button {
            activate(result)
        } label: {
            if let answer = result.answer {
                BifrostAnswerCard(answer: answer, isSelected: result.id == model.selectedID)
            } else {
                BifrostResultRow(
                    result: result, isSelected: result.id == model.selectedID,
                    shortcut: store.mode == .launcher ? model.shortcutNumber(for: result.id) : nil,
                    showsAccessory: store.mode == .launcher)
            }
        }
        .buttonStyle(.edith(.borderless))
        .id(result.id)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let location = NSEvent.mouseLocation
            guard location != lastMouse else { return }
            lastMouse = location
            model.select(result.id)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: store.mode.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(store.mode.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            BifrostHint(label: primaryLabel, keys: "return")
            BifrostHint(label: "Copy", keys: "option return")
            if store.mode != .launcher {
                BifrostHint(label: "Back", keys: "escape")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: BifrostPanelMetrics.footerHeight)
    }

    private var primaryLabel: String {
        guard store.mode == .launcher else { return store.mode.primaryAction }
        return model.selected?.action.isRepeatable == true ? "Open" : "Copy"
    }

    private func leaveMode() {
        store.leaveMode()
        model.reset()
        searchFocused = true
        publishHeight()
    }

    private func activate(_ result: BifrostResult?, copyOnly: Bool = false) {
        guard let result else { return }
        let query = model.query
        if case .run(let commandID) = result.action,
            BifrostCommandCatalog.command(id: commandID)?.mode != nil, !copyOnly
        {
            store.run(result, query: query)
            model.reset()
            searchFocused = true
            publishHeight()
            return
        }
        onDismiss()
        if copyOnly {
            store.copy(result)
            return
        }
        store.run(result, query: query)
    }
}

struct BifrostDetailPane: View {
    let detail: BifrostDetail?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if let detail {
                    preview(detail)
                    Text(detail.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(detail.rows) { row in
                            HStack(alignment: .top, spacing: 12) {
                                Text(row.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(row.value)
                                    .font(.system(size: 12))
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(3)
                            }
                        }
                    }
                } else {
                    Text("Nothing selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func preview(_ detail: BifrostDetail) -> some View {
        if let path = detail.imagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let text = detail.text, !text.isEmpty {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.05))
                )
        }
    }
}

struct BifrostSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: BifrostPanelMetrics.sectionHeaderHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BifrostResultRow: View {
    let result: BifrostResult
    let isSelected: Bool
    var shortcut: Int?
    var showsAccessory = true

    var body: some View {
        HStack(spacing: 11) {
            BifrostResultIcon(result: result)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if result.kind != .application, !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            if showsAccessory {
                Text(result.accessoryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let shortcut {
                Text("\u{2318}\(shortcut)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(isSelected ? 0.14 : 0.07))
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: BifrostPanelMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.14 : 0))
        )
        .padding(.horizontal, 6)
    }
}

struct BifrostAnswerCard: View {
    let answer: BifrostAnswer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            side(answer.input, caption: answer.inputCaption)
            VStack(spacing: 5) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let footnote = answer.footnote {
                    Text(footnote)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 150)
            side(answer.output, caption: answer.outputCaption)
        }
        .padding(.horizontal, 14)
        .frame(height: BifrostPanelMetrics.answerHeight - 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.16 : 0.07), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func side(_ value: String, caption: String) -> some View {
        VStack(spacing: 8) {
            Text(value)
                .font(.system(size: 21, weight: .semibold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct BifrostResultIcon: View {
    let result: BifrostResult

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if result.iconPath != nil {
                BifrostSkeletonSquare()
            } else {
                Image(systemName: result.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: result.id) {
            guard let path = result.iconPath else { return }
            icon = BifrostIconCache.shared.icon(forFile: path)
        }
    }
}

struct BifrostSkeletonSquare: View {
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.white.opacity(shimmer ? 0.16 : 0.08))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    shimmer = true
                }
            }
    }
}

struct BifrostSkeletonPill: View {
    @State private var shimmer = false

    var body: some View {
        Capsule()
            .fill(.white.opacity(shimmer ? 0.22 : 0.10))
            .frame(width: 48, height: 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    shimmer = true
                }
            }
    }
}

struct BifrostHint: View {
    let label: String
    let keys: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(BifrostHint.glyphs(for: keys))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.10))
                )
        }
    }

    static func glyphs(for keys: String) -> String {
        var text = ""
        for key in keys.split(separator: " ") {
            switch key {
            case "return": text += "\u{21A9}"
            case "option": text += "\u{2325}"
            case "command": text += "\u{2318}"
            case "shift": text += "\u{21E7}"
            case "escape": text += "\u{238B}"
            default: text += key.uppercased()
            }
        }
        return text
    }
}

@MainActor
final class BifrostIconCache {
    static let shared = BifrostIconCache()

    private var icons: [String: NSImage] = [:]

    func icon(forFile path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 22, height: 22)
        icons[path] = icon
        return icon
    }
}
