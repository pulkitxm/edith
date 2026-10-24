import EdithKit
import SwiftUI

struct HerdrFilterButton: View {
    var store: HerdrStore
    @Binding var presented: Bool
    var hideAgents: Bool
    var onPress: () -> Void
    var onDismissed: () -> Void
    var onOpenSpace: (HerdrAgentSpace) -> Void
    var onEditLaunch: () -> Void

    private var chips: [HerdrSessionFilterChip] { currentChips }

    var body: some View {
        WorkspaceFilterButton(
            presented: $presented,
            count: chips.count + (store.accountFilter == nil ? 0 : 1),
            label: "Filter sessions",
            summary: HerdrSessionFilters.summary(of: chips)
                + (store.accountFilter == nil ? "" : ", Claude account filter active"),
            help: "Filter by machine, agent, Claude account, or space (⇧⌘F)",
            onPress: onPress, onDismissed: onDismissed
        ) {
            HerdrFilterMenu(
                store: store, hideAgents: hideAgents, onOpenSpace: onOpenSpace,
                onEditLaunch: onEditLaunch,
                dismiss: { presented = false })
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

    private var dark: Bool { scheme == .dark }

    private func rows(matching query: String) -> [HerdrSessionFilterRow] {
        HerdrSessionFilters.rows(
            query: query,
            machines: store.machineChoices,
            kinds: store.kindChoices,
            machineID: store.machineFilter,
            selectedKinds: store.kindFilter,
            groupsBySpace: store.spaceGroupingEnabled,
            spaces: store.agentSpaces.map { ($0.id, $0.title) })
    }

    private var removedAccountIDs: [String] {
        Set(store.accountSessions.values)
            .subtracting(store.claudeAccounts.state.accounts.map { $0.id.uuidString }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Picker(
                "Claude account",
                selection: Binding(
                    get: { store.accountFilter }, set: { store.accountFilter = $0 })
            ) {
                Text("All accounts").tag(String?.none)
                Text("Existing CLI login").tag(Optional("cli"))
                ForEach(store.claudeAccounts.state.accounts) { account in
                    Text(account.name).tag(Optional(account.id.uuidString))
                }
                ForEach(removedAccountIDs, id: \.self) { id in
                    Text("Removed account (\(id.prefix(8)))").tag(Optional(id))
                }
            }
            WorkspaceFilterList(
                label: "Filter sessions", rows: rows, section: { $0.section },
                activate: activate, dismiss: dismiss
            ) { row, highlighted, action in
                rowButton(row, highlighted: highlighted, action: action)
            }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(288))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session filters")
        .pageTask { await store.claudeAccounts.read() }
    }

    private func rowButton(
        _ row: HerdrSessionFilterRow, highlighted: Bool, action: @escaping () -> Void
    ) -> some View {
        let space = isSpace(row)
        return WorkspaceFilterRowButton(highlighted: highlighted, action: action) {
            Image(systemName: symbol(for: row))
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(markColor(row))
                .frame(width: UIScale.pt(14), height: UIScale.pt(14))
            if let kind = kindMark(row) {
                HerdrKindMark(kind: kind, size: UIScale.pt(13))
            }
            Text(row.title)
                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
                .presenterTextBlur(hideAgents && space, fontSize: 12.5)
        }
        .accessibilityLabel(accessibleTitle(row, space: space))
        .accessibilityAddTraits(row.selected && row.toggles ? .isSelected : [])
        .modifier(HerdrFilterRowHint(text: rowHint(row)))
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

    private func rowHint(_ row: HerdrSessionFilterRow) -> String {
        guard case .agent(let id) = row.action, id != "all" else { return "" }
        return "Command-click to show only this agent."
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

private struct HerdrFilterRowHint: ViewModifier {
    var text: String

    @ViewBuilder func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content.accessibilityHint(text)
        }
    }
}
