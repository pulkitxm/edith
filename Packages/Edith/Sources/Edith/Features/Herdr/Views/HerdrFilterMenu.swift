import EdithKit
import SwiftUI

enum HerdrFilterAnchor: Equatable {
    case rail
    case bar
}

struct HerdrFilterButton: View {
    var store: HerdrStore
    var anchor: HerdrFilterAnchor
    @Binding var presented: HerdrFilterAnchor?
    var compact: Bool
    var hideAgents: Bool
    var onPress: () -> Void
    var onDismissed: () -> Void
    var onOpenSpace: (HerdrAgentSpace) -> Void
    var onEditLaunch: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var chips: [HerdrSessionFilterChip] { currentChips }
    private var active: Bool { !chips.isEmpty }

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                if !compact {
                    Text("Filter")
                        .font(.system(size: UIScale.pt(11), weight: .semibold))
                }
            }
            .foregroundStyle(active ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            .frame(minWidth: UIScale.pt(22), minHeight: UIScale.pt(22))
            .padding(.horizontal, UIScale.pt(compact ? 4 : 8))
            .padding(.vertical, UIScale.pt(4))
            .widgetBar(
                cornerRadius: 8,
                fill: active ? DashSkin.accent(dark).opacity(0.18) : DashSkin.paper2(dark),
                stroke: active ? DashSkin.accent(dark).opacity(0.65) : DashSkin.line(dark),
                strokeWidth: active ? 1.4 : 1
            )
            .overlay(alignment: .topTrailing) { badge }
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel("Filter sessions")
        .accessibilityValue(HerdrSessionFilters.summary(of: chips))
        .help("Filter by machine, agent, or space (⇧⌘F)")
        .popover(isPresented: popoverPresented, arrowEdge: anchor == .bar ? .top : .leading) {
            HerdrFilterMenu(
                store: store, hideAgents: hideAgents, onOpenSpace: onOpenSpace,
                onEditLaunch: onEditLaunch,
                dismiss: { presented = nil })
        }
    }

    private var popoverPresented: Binding<Bool> {
        Binding(
            get: { presented == anchor },
            set: { isPresented in
                if isPresented {
                    presented = anchor
                } else if presented == anchor {
                    presented = nil
                    onDismissed()
                }
            })
    }

    @ViewBuilder private var badge: some View {
        if active {
            Text(chips.count > 9 ? "9+" : "\(chips.count)")
                .font(DashSkin.mono(8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, UIScale.pt(3))
                .padding(.vertical, UIScale.pt(1))
                .background(DashSkin.accent(dark), in: Capsule())
                .offset(x: UIScale.pt(4), y: UIScale.pt(-4))
                .accessibilityHidden(true)
        }
    }

    private var currentChips: [HerdrSessionFilterChip] {
        let name =
            store.machineChoices.first { $0.id == store.machineFilter }?.name ?? store.machineFilter
        return HerdrSessionFilters.chips(
            machineID: store.machineFilter,
            machineName: name,
            kinds: store.kindFilter,
            groupsBySpace: store.spaceGroupingEnabled)
    }
}

struct HerdrAgentFilterRow: View {
    var store: HerdrStore
    @Binding var presented: HerdrFilterAnchor?
    var hideAgents: Bool
    var onPress: () -> Void
    var onDismissed: () -> Void
    var onOpenSpace: (HerdrAgentSpace) -> Void
    var onEditLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HerdrFilterButton(
                store: store, anchor: .rail, presented: $presented, compact: false,
                hideAgents: hideAgents, onPress: onPress, onDismissed: onDismissed,
                onOpenSpace: onOpenSpace, onEditLaunch: onEditLaunch)
            HerdrFilterChips(store: store) { presented = .rail }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIScale.pt(8))
        .padding(.bottom, UIScale.pt(6))
        .accessibilityElement(children: .contain)
    }
}

struct HerdrFilterChips: View {
    var store: HerdrStore
    var onOpen: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let chips = currentChips
        if !chips.isEmpty {
            HerdrChipWrap(spacing: UIScale.pt(6), lineSpacing: UIScale.pt(6)) {
                ForEach(chips) { chip in
                    chipView(chip)
                }
            }
        }
    }

    private func chipView(_ chip: HerdrSessionFilterChip) -> some View {
        HStack(spacing: UIScale.pt(4)) {
            Button(action: onOpen) {
                HStack(spacing: UIScale.pt(4)) {
                    if case .kind(let kind) = chip.removal {
                        HerdrKindMark(kind: kind, size: UIScale.pt(11))
                    }
                    Text(chip.key)
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Text(chip.value)
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel(chip.accessibilityLabel)
            .help("Change \(chip.key.lowercased()) filter")
            Button {
                remove(chip)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: UIScale.pt(8), weight: .bold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(12), height: UIScale.pt(12))
            }
            .buttonStyle(.edith(.borderless))
            .accessibilityLabel(chip.removeLabel)
        }
        .font(.system(size: UIScale.pt(11), weight: .medium))
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(4))
        .widgetBar(
            cornerRadius: 8,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark))
    }

    private func remove(_ chip: HerdrSessionFilterChip) {
        let change = {
            switch chip.removal {
            case .machine:
                store.machineFilter = "all"
            case .kind(let kind):
                store.selectKind(kind, exclusive: false)
            case .grouping:
                store.spaceGroupingEnabled = false
            }
        }
        if case .grouping = chip.removal {
            withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), change)
        } else {
            change()
        }
    }

    private var currentChips: [HerdrSessionFilterChip] {
        let name =
            store.machineChoices.first { $0.id == store.machineFilter }?.name ?? store.machineFilter
        return HerdrSessionFilters.chips(
            machineID: store.machineFilter,
            machineName: name,
            kinds: store.kindFilter,
            groupsBySpace: store.spaceGroupingEnabled)
    }
}

private struct HerdrFilterMenu: View {
    var store: HerdrStore
    var hideAgents: Bool
    var onOpenSpace: (HerdrAgentSpace) -> Void
    var onEditLaunch: () -> Void
    var dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var highlight = 0
    @State private var scrollToken = 0
    @State private var listHeight: CGFloat = 44

    private var dark: Bool { scheme == .dark }

    private var rows: [HerdrSessionFilterRow] {
        HerdrSessionFilters.rows(
            query: query,
            machines: store.machineChoices,
            kinds: store.kindChoices,
            machineID: store.machineFilter,
            selectedKinds: store.kindFilter,
            groupsBySpace: store.spaceGroupingEnabled,
            spaces: store.agentSpaces.map { ($0.id, $0.title) })
    }

    private var resolvedHighlight: Int {
        guard !rows.isEmpty else { return 0 }
        return min(highlight, rows.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            search
            if rows.isEmpty {
                Text("No matching filters")
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(6))
            } else {
                list
            }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(288))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session filters")
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in
            highlight = 0
            scrollToken += 1
        }
    }

    private var search: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(13)))
                .disableAutocorrection(true)
                .focused($searchFocused)
                .accessibilityLabel("Filter sessions")
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    highlight = HerdrSessionFilters.highlight(
                        resolvedHighlight,
                        movingBy: press.key == .upArrow ? -1 : 1,
                        count: rows.count)
                    scrollToken += 1
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { _ in
                    if rows.indices.contains(resolvedHighlight) {
                        activate(rows[resolvedHighlight])
                    }
                    return .handled
                }
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(6))
        .widgetBar(
            cornerRadius: 8, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || rows[index - 1].section != row.section {
                            sectionTitle(row.section, first: index == 0)
                        }
                        rowButton(row, index: index)
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: HerdrFilterMenuHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 44), UIScale.pt(420)))
            .onPreferenceChange(HerdrFilterMenuHeightKey.self) { listHeight = $0 }
            .onChange(of: scrollToken) { _, _ in
                guard rows.indices.contains(resolvedHighlight) else { return }
                proxy.scrollTo(rows[resolvedHighlight].id, anchor: .center)
            }
        }
    }

    private func sectionTitle(_ title: String, first: Bool) -> some View {
        Text(title)
            .font(.system(size: UIScale.pt(10), weight: .semibold))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.top, UIScale.pt(first ? 2 : 10))
            .padding(.bottom, UIScale.pt(2))
            .accessibilityAddTraits(.isHeader)
    }

    private func rowButton(_ row: HerdrSessionFilterRow, index: Int) -> some View {
        let highlighted = index == resolvedHighlight
        let space = isSpace(row)
        return Button {
            highlight = index
            activate(row)
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: symbol(for: row))
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(markColor(row))
                    .frame(width: UIScale.pt(14), height: UIScale.pt(14))
                if let kind = kindMark(row) {
                    HerdrKindMark(kind: kind, size: UIScale.pt(13))
                }
                Text(row.title)
                    .font(
                        .system(size: UIScale.pt(12.5), weight: highlighted ? .semibold : .medium)
                    )
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                    .presenterTextBlur(hideAgents && space, fontSize: 12.5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted ? DashSkin.accent(dark).opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(accessibleTitle(row, space: space))
        .accessibilityAddTraits(row.selected && row.toggles ? .isSelected : [])
        .help(help(for: row))
        .id(row.id)
        .onHover { inside in
            if inside { highlight = index }
        }
    }

    private func symbol(for row: HerdrSessionFilterRow) -> String {
        switch row.action {
        case .machine, .agent("all"):
            row.selected ? "checkmark.circle.fill" : "circle"
        case .agent:
            row.selected ? "checkmark.square.fill" : "square"
        case .grouping:
            row.selected ? "checkmark.square.fill" : "square"
        case .space:
            "macwindow"
        case .launch:
            "pencil"
        case .clear:
            "xmark"
        }
    }

    private func markColor(_ row: HerdrSessionFilterRow) -> Color {
        if row.selected, row.toggles { return DashSkin.accent(dark) }
        return DashSkin.inkFaint(dark)
    }

    private func kindMark(_ row: HerdrSessionFilterRow) -> String? {
        guard case .agent(let kind) = row.action, kind != "all" else { return nil }
        return kind
    }

    private func isSpace(_ row: HerdrSessionFilterRow) -> Bool {
        if case .space = row.action { return true }
        return false
    }

    private func accessibleTitle(_ row: HerdrSessionFilterRow, space: Bool) -> String {
        guard space, hideAgents else { return row.accessibilityLabel }
        return "Open space in a new window"
    }

    private func help(for row: HerdrSessionFilterRow) -> String {
        switch row.action {
        case .machine:
            "Show sessions on \(row.title)"
        case .agent("all"):
            "Show every agent"
        case .agent:
            "Click to add or remove. Command-click to show only this agent."
        case .grouping:
            "Group the agent list by space"
        case .space:
            hideAgents ? "Open space in a new window" : "Open \(row.title) in a new window"
        case .launch:
            "Edit the launch command, model, effort and fast mode for each agent kind"
        case .clear:
            "Clear machine, agent, and space grouping filters"
        }
    }

    private func activate(_ row: HerdrSessionFilterRow) {
        switch row.action {
        case .machine(let id):
            store.machineFilter = id
        case .agent(let id):
            store.selectKind(id, exclusive: NSEvent.modifierFlags.contains(.command))
        case .grouping:
            withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                store.spaceGroupingEnabled.toggle()
            }
        case .space(let id):
            guard let space = store.agentSpaces.first(where: { $0.id == id }) else { return }
            dismiss()
            onOpenSpace(space)
        case .launch:
            dismiss()
            onEditLaunch()
        case .clear:
            store.clearSessionFilters()
        }
    }
}

private struct HerdrFilterMenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HerdrChipWrap: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let frames = arrange(proposal: proposal, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (
        size: CGSize, frames: [CGRect]
    ) {
        let limit = proposal.width ?? .greatestFiniteMagnitude
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
        }
        let width = proposal.width ?? usedWidth
        return (CGSize(width: width, height: y + lineHeight), frames)
    }
}
