import AppKit
import EdithKit
import SwiftUI

@MainActor
final class PaneViewStore {
    static let shared = PaneViewStore()

    private struct Key: Hashable {
        let tab: UUID
        let machine: UUID
    }

    private var finders: [Key: FinderModel] = [:]
    private var terminals: [Key: TerminalSessionHolder] = [:]

    private init() {}

    func finder(for tabID: UUID, session: MachineSession) -> FinderModel {
        let key = Key(tab: tabID, machine: session.id)
        if let existing = finders[key] { return existing }
        let model = FinderModel(session: session)
        finders[key] = model
        return model
    }

    func terminal(for tabID: UUID, session: MachineSession) -> TerminalSessionHolder {
        let key = Key(tab: tabID, machine: session.id)
        if let existing = terminals[key] { return existing }
        let holder = TerminalSessionHolder()
        terminals[key] = holder
        return holder
    }

    func terminalView(tabID: UUID, machineID: UUID) -> NSView? {
        terminals[Key(tab: tabID, machine: machineID)]?.terminalView
    }

    func release(tabID: UUID) {
        finders = finders.filter { $0.key.tab != tabID }
        for (key, holder) in terminals where key.tab == tabID {
            holder.stop()
            terminals.removeValue(forKey: key)
        }
    }

    func releaseAll(except live: Set<UUID>) {
        finders = finders.filter { live.contains($0.key.tab) }
        for (key, holder) in terminals where !live.contains(key.tab) {
            holder.stop()
            terminals.removeValue(forKey: key)
        }
    }
}

struct PaneContentIdentity: Hashable {
    let tab: UUID
    let target: PaneTarget
}

struct PaneContentView: View {
    let session: MachineSession
    let machines: MachinesModel
    let screen: PaneScreen
    let tabID: UUID

    var body: some View {
        switch screen {
        case .overview: MachineOverviewTab(session: session)
        case .processes: MachineProcessesTab(session: session)
        case .docker: DockerConsoleView(session: session)
        case .terminal:
            MachineTerminalTab(
                session: session,
                holder: PaneViewStore.shared.terminal(for: tabID, session: session))
        case .files:
            FinderPane(model: PaneViewStore.shared.finder(for: tabID, session: session))
        case .tools: MachineToolsTab(session: session, model: machines)
        }
    }
}

struct WorkspacePaneView: View {
    let pane: PaneNode
    let model: WorkspaceModel
    let machines: MachinesModel
    let dark: Bool
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled

    private var focused: Bool { model.layout.focused == pane.id }

    private var selectedTab: PaneTab? {
        pane.tabs.first { $0.id == pane.selected } ?? pane.tabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().opacity(0.3)
            content
                .padding(.top, UIScale.pt(8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashSkin.paper(dark))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(6))
                .strokeBorder(
                    focused ? DashSkin.accent(dark).opacity(0.7) : DashSkin.line(dark),
                    lineWidth: UIScale.pt(focused ? 2 : 1))
        }
        .animation(.easeOut(duration: 0.16), value: focused)
        .contentShape(Rectangle())
        .onTapGesture { model.apply { $0.focused = pane.id } }
        .onChange(of: focused) { _, isFocused in
            guard isFocused else { return }
            moveKeyboardFocusHere()
        }
    }

    private func moveKeyboardFocusHere() {
        guard let tab = selectedTab else { return }
        let window = NSApp.keyWindow
        guard let window else { return }
        if tab.target.screen == .terminal,
            let view = PaneViewStore.shared.terminalView(
                tabID: tab.id, machineID: tab.target.machineID)
        {
            window.makeFirstResponder(view)
        } else {
            window.makeFirstResponder(window.contentView)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !connectionsEnabled || pane.tabs.isEmpty {
            Color.clear
        } else {
            ZStack {
                ForEach(pane.tabs) { tab in
                    let live = tab.id == (selectedTab?.id ?? pane.selected)
                    PaneContentView(
                        session: machines.session(for: tab.target.machineID),
                        machines: machines, screen: tab.target.screen, tabID: tab.id
                    )
                    .id(PaneContentIdentity(tab: tab.id, target: tab.target))
                    .opacity(live ? 1 : 0)
                    .allowsHitTesting(live)
                    .accessibilityHidden(!live)
                }
            }
        }
    }

    private var paneMachineID: UUID? {
        selectedTab?.target.machineID ?? pane.tabs.first?.target.machineID
    }

    private var machinePicker: some View {
        let machineID = paneMachineID
        let machine = machines.allMachines.first { $0.id == machineID }
        let session = machineID.map { machines.session(for: $0) }
        return Menu {
            ForEach(machines.allMachines) { candidate in
                Button(candidate.name) { retargetPane(to: candidate.id) }
            }
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                if let session {
                    Circle()
                        .fill(MachineStatusStyle.color(session.state, dark: dark))
                        .frame(width: UIScale.pt(5), height: UIScale.pt(5))
                }
                Text(machine?.name ?? "Machine")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: UIScale.pt(7), weight: .bold))
            }
            .foregroundStyle(DashSkin.ink(dark))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show a different machine in this pane")
    }

    private func retargetPane(to machineID: UUID) {
        let available = PaneScreen.available(
            isLocal: machines.isLocal(machineID),
            hasDocker: machines.session(for: machineID).docker.isInstalled)
        for tab in pane.tabs {
            let screen = available.contains(tab.target.screen) ? tab.target.screen : .overview
            model.retargetPane(
                pane.id, tabID: tab.id,
                to: PaneTarget(machineID: machineID, screen: screen))
            PaneViewStore.shared.release(tabID: tab.id)
        }
    }

    private var addableScreens: [PaneScreen] {
        guard let machineID = paneMachineID else { return [] }
        return PaneScreen.available(
            isLocal: machines.isLocal(machineID),
            hasDocker: machines.session(for: machineID).docker.isInstalled)
    }

    private var tabStrip: some View {
        HStack(spacing: UIScale.pt(3)) {
            machinePicker
            Divider().frame(height: UIScale.pt(12)).opacity(0.4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(3)) {
                    ForEach(pane.tabs) { tab in
                        tabChip(tab)
                    }
                }
            }
            Menu {
                ForEach(addableScreens, id: \.self) { screen in
                    Button(screen.title) {
                        guard let machineID = paneMachineID else { return }
                        model.addTab(
                            to: pane.id,
                            target: PaneTarget(machineID: machineID, screen: screen))
                    }
                }
                Divider()
                ForEach(machines.allMachines) { machine in
                    Menu(machine.name) {
                        ForEach(
                            PaneScreen.available(
                                isLocal: machines.isLocal(machine.id),
                                hasDocker: machines.session(for: machine.id).docker.isInstalled),
                            id: \.self
                        ) { screen in
                            Button(screen.title) {
                                model.addTab(
                                    to: pane.id,
                                    target: PaneTarget(machineID: machine.id, screen: screen))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a view to this pane")

            Menu {
                Button("Split Right") { split(.right) }
                Button("Split Down") { split(.bottom) }
                Divider()
                Button("Close Pane") {
                    let orphans = pane.tabs.map(\.id)
                    model.apply { $0.closePane(pane.id) }
                    for id in orphans { PaneViewStore.shared.release(tabID: id) }
                }
                .disabled(model.layout.paneCount < 2)
            } label: {
                Image(systemName: "square.split.2x1")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Split or close this pane")
        }
        .padding(.horizontal, UIScale.pt(9))
        .padding(.vertical, UIScale.pt(8))
        .background(.thinMaterial)
    }

    private func split(_ side: InsertSide) {
        guard let target = selectedTab?.target else { return }
        model.apply { $0.split(paneID: pane.id, side: side, target: target) }
    }

    private func tabChip(_ tab: PaneTab) -> some View {
        let machine = machines.allMachines.first { $0.id == tab.target.machineID }
        let foreign = tab.target.machineID != paneMachineID
        let selected = tab.id == pane.selected
        return Button {
            model.apply { layout in
                layout.focused = pane.id
                layout.root.updatePane(pane.id) { $0.selected = tab.id }
            }
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: tab.target.screen.icon)
                    .font(.system(size: UIScale.pt(9.5)))
                Text(
                    foreign
                        ? "\(machine?.name ?? "Machine") · \(tab.target.screen.title)"
                        : tab.target.screen.title
                )
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .lineLimit(1)
                Button {
                    closeTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(7.5), weight: .bold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(UIScale.pt(2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Close this tab")
            }
            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(4))
            .background(
                selected ? DashSkin.paper2(dark) : .clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .contextMenu {
            Button("Close Tab") { closeTab(tab) }
            Divider()
            ForEach(machines.allMachines) { machine in
                Menu(machine.name) {
                    ForEach(
                        PaneScreen.available(
                            isLocal: machines.isLocal(machine.id),
                            hasDocker: machines.session(for: machine.id).docker.isInstalled),
                        id: \.self
                    ) { screen in
                        Button(screen.title) {
                            model.retargetPane(
                                pane.id, tabID: tab.id,
                                to: PaneTarget(machineID: machine.id, screen: screen))
                            PaneViewStore.shared.release(tabID: tab.id)
                        }
                    }
                }
            }
        }
    }

    private func closeTab(_ tab: PaneTab) {
        if pane.tabs.count > 1 {
            model.closeTab(tab.id, in: pane.id)
            PaneViewStore.shared.release(tabID: tab.id)
        } else if model.layout.paneCount > 1 {
            let orphans = pane.tabs.map(\.id)
            model.apply { $0.closePane(pane.id) }
            for id in orphans { PaneViewStore.shared.release(tabID: id) }
        }
    }
}
