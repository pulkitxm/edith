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
        _model = State(initialValue: BifrostPanelModel(resolve: { store.results(for: $0) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !model.sections.isEmpty {
                Divider().opacity(0.25)
                resultList
                footer
            }
        }
        .frame(width: BifrostPanelMetrics.width, height: model.height, alignment: .top)
        .background(BifrostPanelMetrics.scrim)
        .edithGlass(in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: model.selectedID)
        .onAppear {
            searchFocused = true
            lastMouse = NSEvent.mouseLocation
            publishHeight()
        }
        .onChange(of: model.height) { _, _ in publishHeight() }
        .onChange(of: store.revision) { _, _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: BifrostPanel.willShow)) { note in
            model.reset(query: note.userInfo?[BifrostPanel.prefillKey] as? String ?? "")
            searchFocused = true
            lastMouse = NSEvent.mouseLocation
            publishHeight()
        }
        .onReceive(NotificationCenter.default.publisher(for: BifrostPanel.didHide)) { _ in
            model.reset()
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BifrostPanelMetrics.cornerRadius, style: .continuous)
    }

    private func publishHeight() {
        onHeightChanged(model.height)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(nsImage: Logo.header)
                .resizable()
                .frame(width: 20, height: 20)
                .opacity(0.9)
            TextField("Search apps, commands, sums and units", text: queryBinding)
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
                    onDismiss()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    activate(model.selected, copyOnly: press.modifiers.contains(.option))
                    return .handled
                }
            if store.isIndexing {
                BifrostSkeletonPill()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: BifrostPanelMetrics.headerHeight)
    }

    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.setQuery($0) })
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
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
            .frame(height: model.listHeight)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ result: BifrostResult) -> some View {
        Button {
            activate(result)
        } label: {
            BifrostResultRow(result: result, isSelected: result.id == model.selectedID)
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
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            BifrostHint(
                label: model.selected?.action.isRepeatable == true ? "Open" : "Copy",
                keys: "return")
            BifrostHint(label: "Copy", keys: "option return")
        }
        .padding(.horizontal, 14)
        .frame(height: BifrostPanelMetrics.footerHeight)
        .background(.white.opacity(0.04))
    }

    private func activate(_ result: BifrostResult?, copyOnly: Bool = false) {
        guard let result else { return }
        let query = model.query
        onDismiss()
        if copyOnly {
            store.copy(result)
            return
        }
        store.run(result, query: query)
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
            .frame(
                height: BifrostPanelMetrics.sectionHeaderHeight, alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BifrostPanelMetrics.scrim)
    }
}

struct BifrostResultRow: View {
    let result: BifrostResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            BifrostResultIcon(result: result)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if result.kind != .application {
                    Text(result.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            Text(result.accessoryText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
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
