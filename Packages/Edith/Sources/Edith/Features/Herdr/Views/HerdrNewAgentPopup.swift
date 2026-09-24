import EdithKit
import SwiftUI

struct HerdrNewAgentPopup: View {
    let store: HerdrStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var model = HerdrNewAgentPopupModel()
    @State private var selectionIndex = 0
    @FocusState private var fieldFocused: Bool

    private var dark: Bool { scheme == .dark }
    private var hosts: [HerdrHostSnapshot] { store.hosts }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            field
            Divider()
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.red)
                    .padding(UIScale.pt(12))
            }
            resultsList
        }
        .frame(width: UIScale.pt(440), height: UIScale.pt(380))
        .onAppear { fieldFocused = true }
        .onChange(of: model.step) { _, step in
            selectionIndex = 0
            if step == .space { loadWorkspaces() }
        }
        .onChange(of: currentQuery) { _, _ in selectionIndex = 0 }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(selectionIndex, anchor: .center)
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            ForEach(
                [
                    ("Kind", HerdrNewAgentPopupModel.Step.kind), ("Machine", .machine),
                    ("Space", .space),
                ], id: \.1
            ) {
                title, step in
                Text(title)
                    .font(
                        .system(
                            size: UIScale.pt(11), weight: step == model.step ? .semibold : .regular)
                    )
                    .foregroundStyle(step == model.step ? .primary : .secondary)
                if step != .space {
                    Image(systemName: "chevron.right").font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if model.launching {
                Text("Launching…")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            layoutChoiceMenu
        }
        .padding(UIScale.pt(14))
    }

    private var layoutChoiceMenu: some View {
        Menu {
            Picker("Layout", selection: $model.layoutChoice) {
                ForEach(HerdrNewAgentPopupModel.LayoutChoice.allCases) { choice in
                    Label(choice.title, systemImage: choice.symbolName).tag(choice)
                }
            }
        } label: {
            Image(systemName: model.layoutChoice.symbolName)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .frame(width: UIScale.pt(22), height: UIScale.pt(22))
        .help("Choose how the new agent opens: \(model.layoutChoice.title)")
    }

    private var field: some View {
        TextField(placeholder, text: currentQueryBinding)
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(14)))
            .focused($fieldFocused)
            .disabled(model.launching)
            .padding(UIScale.pt(12))
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onKeyPress(.escape) {
                if !model.back() { dismiss() }
                return .handled
            }
            .onKeyPress(keys: [.return, .tab]) { _ in
                activateSelection()
                return .handled
            }
    }

    private var placeholder: String {
        switch model.step {
        case .kind: "Search agent kinds…"
        case .machine: "Search machines…"
        case .space: "Search or name a new space…"
        }
    }

    private var currentQuery: String {
        switch model.step {
        case .kind: model.kindQuery
        case .machine: model.machineQuery
        case .space: model.spaceQuery
        }
    }

    private var currentQueryBinding: Binding<String> {
        switch model.step {
        case .kind: $model.kindQuery
        case .machine: $model.machineQuery
        case .space: $model.spaceQuery
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch model.step {
                    case .kind: kindRows
                    case .machine: machineRows
                    case .space: spaceRows
                    }
                }
            }
            .onChange(of: selectionIndex) { _, _ in scrollToSelection(proxy) }
            .onChange(of: model.step) { _, _ in scrollToSelection(proxy) }
        }
    }

    @ViewBuilder
    private var kindRows: some View {
        let kinds = HerdrNewAgentPopupModel.matchingKinds(model.kindQuery)
        ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
            row(index: index) {
                HerdrKindMark(kind: kind, size: UIScale.pt(16))
                Text(kind).font(.system(size: UIScale.pt(12)))
                Spacer()
            }
        }
        if kinds.isEmpty {
            emptyState("No matching agent kinds")
        }
    }

    @ViewBuilder
    private var machineRows: some View {
        let machines = HerdrNewAgentPopupModel.matchingMachines(model.machineQuery, in: hosts)
        ForEach(Array(machines.enumerated()), id: \.element.id) { index, host in
            let available = host.reachable && host.herdrPresent
            row(index: index) {
                Image(systemName: host.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(available ? .primary : .secondary)
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    Text(host.name).font(.system(size: UIScale.pt(12)))
                    if !available {
                        Text(unavailableReason(host))
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .opacity(available ? 1 : 0.5)
        }
        if machines.isEmpty {
            emptyState("No machines found")
        } else if machines.allSatisfy({ !$0.reachable || !$0.herdrPresent }) {
            refreshRow
        }
    }

    @ViewBuilder
    private var spaceRows: some View {
        let matches = HerdrNewAgentPopupModel.matchingSpaces(model.spaceQuery, in: model.workspaces)
        let trimmedQuery = model.spaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsCreateRow =
            !trimmedQuery.isEmpty
            && HerdrNewAgentPopupModel.matchingSpace(named: trimmedQuery, in: model.workspaces)
                == nil
        if model.loadingWorkspaces {
            HerdrSkeleton(dark: dark, rows: 4, card: false)
        } else {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, space in
                row(index: index) {
                    Image(systemName: "square.split.2x2")
                        .font(.system(size: UIScale.pt(12)))
                    Text(space.label).font(.system(size: UIScale.pt(12)))
                    Spacer()
                    Text("\(space.paneCount) pane\(space.paneCount == 1 ? "" : "s")")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                }
            }
            if showsCreateRow {
                row(index: matches.count) {
                    Image(systemName: "plus.square")
                        .font(.system(size: UIScale.pt(12)))
                    Text("Create space “\(trimmedQuery)”").font(
                        .system(size: UIScale.pt(12)))
                    Spacer()
                }
            }
            if matches.isEmpty, !showsCreateRow {
                emptyState("No spaces yet — type a name to create one")
            }
        }
    }

    private func row<Content: View>(
        index: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            selectionIndex = index
            activateSelection()
        } label: {
            HStack(spacing: UIScale.pt(10)) { content() }
                .padding(.horizontal, UIScale.pt(14))
                .padding(.vertical, UIScale.pt(8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.edith(.selection, selected: index == selectionIndex))
        .id(index)
    }

    private var refreshRow: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Label("Refresh machines", systemImage: "arrow.clockwise")
                .font(.system(size: UIScale.pt(12)))
        }
        .buttonStyle(.edith(.borderless))
        .padding(UIScale.pt(14))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(.secondary)
            .padding(UIScale.pt(20))
    }

    private func unavailableReason(_ host: HerdrHostSnapshot) -> String {
        if !host.reachable { return "Unreachable" }
        if !host.herdrPresent { return "herdr not installed" }
        return host.error ?? "Unavailable"
    }

    private func move(_ delta: Int) {
        let count = currentRowCount
        guard count > 0 else { return }
        selectionIndex = (selectionIndex + delta + count) % count
    }

    private var currentRowCount: Int {
        switch model.step {
        case .kind:
            return HerdrNewAgentPopupModel.matchingKinds(model.kindQuery).count
        case .machine:
            return HerdrNewAgentPopupModel.matchingMachines(model.machineQuery, in: hosts).count
        case .space:
            let matches = HerdrNewAgentPopupModel.matchingSpaces(
                model.spaceQuery, in: model.workspaces)
            let trimmedQuery = model.spaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let showsCreateRow =
                !trimmedQuery.isEmpty
                && HerdrNewAgentPopupModel.matchingSpace(named: trimmedQuery, in: model.workspaces)
                    == nil
            return matches.count + (showsCreateRow ? 1 : 0)
        }
    }

    private func activateSelection() {
        switch model.step {
        case .kind:
            let kinds = HerdrNewAgentPopupModel.matchingKinds(model.kindQuery)
            guard kinds.indices.contains(selectionIndex) else { return }
            model.selectKind(kinds[selectionIndex])
        case .machine:
            let machines = HerdrNewAgentPopupModel.matchingMachines(model.machineQuery, in: hosts)
            guard machines.indices.contains(selectionIndex) else { return }
            model.selectMachine(machines[selectionIndex])
        case .space:
            let matches = HerdrNewAgentPopupModel.matchingSpaces(
                model.spaceQuery, in: model.workspaces)
            if matches.indices.contains(selectionIndex) {
                launch(space: matches[selectionIndex], newLabel: nil)
            } else {
                let trimmedQuery = model.spaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedQuery.isEmpty else { return }
                launch(space: nil, newLabel: trimmedQuery)
            }
        }
    }

    private func loadWorkspaces() {
        guard let host = model.selectedHost else { return }
        model.loadingWorkspaces = true
        model.errorMessage = nil
        Task {
            do {
                model.workspaces = try await HerdrLaunchOperations.listWorkspaces(
                    on: store.machine(for: host))
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.loadingWorkspaces = false
        }
    }

    private func launch(space: HerdrWorkspaceSummary?, newLabel: String?) {
        guard let kind = model.selectedKind, let host = model.selectedHost else { return }
        model.launching = true
        model.errorMessage = nil
        Task {
            do {
                try await store.launchNewAgent(
                    kind: kind, host: host, existingSpace: space, newSpaceLabel: newLabel,
                    openBeside: model.layoutChoice == .sideBySide)
                model.launching = false
                dismiss()
            } catch {
                model.launching = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
