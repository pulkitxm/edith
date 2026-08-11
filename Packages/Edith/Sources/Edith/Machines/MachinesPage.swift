import EdithKit
import SwiftUI

private struct MachineConnectionsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var machineConnectionsEnabled: Bool {
        get { self[MachineConnectionsEnabledKey.self] }
        set { self[MachineConnectionsEnabledKey.self] = newValue }
    }
}

struct MachinesPage: View {
    @StateObject private var model = MachinesModel.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled
    @AppStorage("machinesTab", store: SharedDefaults.store) private var storedTab =
        MachineTab.overview.rawValue
    @AppStorage("machinesSelection", store: SharedDefaults.store) private var storedSelection = ""
    @AppStorage("machinesMode", store: SharedDefaults.store) private var modeRaw = "fleet"
    @State private var addSheetPresented = false
    @State private var editingMachine: Machine?
    @State private var confirmRemoval: Machine?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .sheet(isPresented: $addSheetPresented) {
            AddMachineSheet { machine, secrets in
                model.add(machine)
                store(secrets, for: machine)
            }
        }
        .sheet(item: $editingMachine) { machine in
            AddMachineSheet(editing: machine) { updated, secrets in
                model.update(updated)
                store(secrets, for: updated)
            }
        }
        .confirmationDialog(
            "Remove \(confirmRemoval?.name ?? "machine")?",
            isPresented: Binding(
                get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let machine = confirmRemoval { model.remove(id: machine.id) }
                confirmRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmRemoval = nil }
        } message: {
            Text(
                "Edith forgets the connection details and any saved password. Nothing on the machine changes."
            )
        }
        .onAppear {
            guard connectionsEnabled else { return }
            model.connectAll()
            model.restoreSelection(storedSelection)
            model.startSelected()
            reconcileTab()
        }
        .onChange(of: model.selection) { _, selection in
            guard connectionsEnabled else { return }
            storedSelection = selection?.uuidString ?? ""
            model.startSelected()
            reconcileTab()
        }
    }

    private var tab: MachineTab {
        MachineTab(rawValue: storedTab) ?? .overview
    }

    private func reconcileTab() {
        let hasDocker = model.selection.map { model.session(for: $0).docker.isInstalled } ?? false
        let available = MachineTab.tabs(isLocal: isLocalSelection, hasDocker: hasDocker)
        if !available.contains(tab) { storedTab = MachineTab.overview.rawValue }
    }

    private var isLocalSelection: Bool {
        model.selection.map { model.isLocal($0) } ?? true
    }

    private var header: some View {
        PageHeader(
            "Machines",
            trailing: {
                Button {
                    addSheetPresented = true
                } label: {
                    Label("Add machine", systemImage: "plus")
                }
                .pointerCursor()
            },
            accessory: { machineStrip })
    }

    private var machineStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(10)) {
                FleetChip(
                    title: "All machines", subtitle: "Summary", symbol: "square.grid.2x2",
                    selected: mode == .fleet, dark: dark
                ) { modeRaw = MachinesMode.fleet.rawValue }
                FleetChip(
                    title: "Workspace", subtitle: "Split panes",
                    symbol: "rectangle.split.2x1", selected: mode == .workspace, dark: dark
                ) { modeRaw = MachinesMode.workspace.rawValue }
                if connectionsEnabled {
                    ForEach(model.allMachines) { machine in
                        MachineChip(
                            machine: machine,
                            session: model.session(for: machine.id),
                            selected: mode == .machine && model.selection == machine.id,
                            isLocal: model.isLocal(machine.id), dark: dark,
                            onSelect: {
                                modeRaw = MachinesMode.machine.rawValue
                                model.selection = machine.id
                            },
                            onDetach: {
                                MachineWindow.open(machineID: machine.id, title: machine.name)
                            },
                            onEdit: { editingMachine = machine },
                            onRemove: { confirmRemoval = machine })
                    }
                }
            }
            .padding(.vertical, UIScale.pt(2))
        }
    }

    private var mode: MachinesMode {
        MachinesMode(rawValue: modeRaw) ?? .fleet
    }

    @ViewBuilder
    private var content: some View {
        if !connectionsEnabled {
            Color.clear
        } else if mode == .fleet {
            FleetHomeView(model: model) { id in
                modeRaw = MachinesMode.machine.rawValue
                model.selection = id
            }
        } else if mode == .workspace {
            WorkspaceView(machines: model)
        } else if let session = model.selectedSession() {
            MachineDetailView(
                session: session, model: model,
                tab: Binding(
                    get: { tab },
                    set: { storedTab = $0.rawValue }))
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: UIScale.pt(12)) {
            Image(systemName: "server.rack")
                .font(.system(size: UIScale.pt(38)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text("No machines yet")
                .font(DashSkin.serif(20))
                .foregroundStyle(DashSkin.ink(dark))
            Text(
                "Add a computer you can reach over SSH to watch its resources, browse its files, and run its containers."
            )
            .font(.system(size: UIScale.pt(12.5)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .multilineTextAlignment(.center)
            .frame(maxWidth: UIScale.pt(420))
            Button("Add machine") { addSheetPresented = true }
                .pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func store(_ secrets: AddMachineSheet.Secrets, for machine: Machine) {
        if let login = secrets.login {
            let kind: MachineSecretKind = machine.auth == .password ? .password : .passphrase
            MachineSecrets.set(login, machineID: machine.id, kind: kind)
        }
        if let sudo = secrets.sudo {
            MachineSecrets.set(sudo, machineID: machine.id, kind: .sudoPassword)
        }
        if secrets.forgetSudo {
            MachineSecrets.delete(machineID: machine.id, kind: .sudoPassword)
        }
    }
}

private struct MachineChip: View {
    let machine: Machine
    @ObservedObject var session: MachineSession
    let selected: Bool
    let isLocal: Bool
    let dark: Bool
    let onSelect: () -> Void
    let onDetach: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if SectionWindowCommand.shouldDetach(NSEvent.modifierFlags.swiftUIValue) {
                onDetach()
            } else {
                onSelect()
            }
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(selected ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    Text(machine.name)
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Text(isLocal ? "Local" : machine.subtitle)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
                Circle()
                    .fill(MachineStatusStyle.color(session.state, dark: dark))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
            }
            .padding(.horizontal, UIScale.pt(11))
            .padding(.vertical, UIScale.pt(8))
            .background(
                selected ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55),
                in: RoundedRectangle(cornerRadius: UIScale.pt(11))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(11))
                    .strokeBorder(
                        selected ? DashSkin.accent(dark).opacity(0.55) : DashSkin.line(dark),
                        lineWidth: UIScale.pt(selected ? 1.4 : 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering = $0 }
        .help("\(machine.name) (⌘-click to open in its own window)")
        .contextMenu {
            Button("Open in New Window", action: onDetach)
            if !isLocal {
                Divider()
                Button("Edit…", action: onEdit)
                Button(session.state == .disconnected ? "Connect" : "Disconnect") {
                    session.state == .disconnected ? session.start() : session.stop()
                }
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
    }
}
