import EdithKit
import SwiftUI

private enum QuinjetMachinePickerMode: String, CaseIterable, Identifiable {
    case recent
    case browse

    var id: String { rawValue }
    var title: String { self == .recent ? "Recent projects" : "Browse folders" }
}

struct QuinjetProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab

    @State private var machines = MachinesModel.shared

    var body: some View {
        Group {
            if machines.isLocal(tab.machineID) {
                QuinjetLocalProjectPicker(
                    model: model, tab: tab, machines: machines, selectMachine: select)
            } else if let machine = selectedMachine, let picker = tab.folderPicker,
                let remote = remote(for: machine)
            {
                QuinjetRemoteProjectPicker(
                    model: model, tab: tab, machines: machines, machine: machine, remote: remote,
                    picker: picker, selectMachine: select)
            } else {
                ProgressView("Preparing machine")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { reconcileSelection() }
    }

    private var selectedMachine: Machine? {
        machines.allMachines.first { $0.id == tab.machineID }
    }

    private func reconcileSelection() {
        guard let machine = selectedMachine else {
            select(machines.localMachine)
            return
        }
        guard !machines.isLocal(machine.id) else { return }
        if tab.folderPicker == nil {
            select(machine)
        } else if let remote = remote(for: machine), model.projects(for: remote).isEmpty {
            Task { await model.refreshProjects(for: remote) }
        }
    }

    private func select(_ machine: Machine) {
        tab.machineID = machine.id
        model.projectError = nil
        guard !machines.isLocal(machine.id) else {
            tab.folderPicker = nil
            if model.projects.isEmpty { Task { await model.refreshProjects() } }
            return
        }
        let picker = QuinjetFolderPickerModel(session: machines.session(for: machine.id))
        tab.folderPicker = picker
        Task {
            await picker.start()
            if let remote = remote(for: machine) { await model.refreshProjects(for: remote) }
        }
    }

    private func remote(for machine: Machine) -> QuinjetRemote? {
        let session = machines.session(for: machine.id)
        guard let connection = session.connectionRef else { return nil }
        return QuinjetRemote(
            machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
            controlPath: connection.controlSocketPath,
            platform: session.remotePlatform ?? .linux)
    }
}

private struct QuinjetRemoteProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab
    let machines: MachinesModel
    let machine: Machine
    let remote: QuinjetRemote
    @Bindable var picker: QuinjetFolderPickerModel
    let selectMachine: (Machine) -> Void

    @State private var mode = QuinjetMachinePickerMode.recent

    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @Environment(\.quinjetLaunchConfiguration) private var configuration

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Open a project")
                    Text(
                        mode == .recent
                            ? "Recent Quinjet workspaces on \(machine.name)"
                            : "Browse live folders on \(machine.name)"
                    )
                    .font(.system(size: UIScale.pt(12), weight: .regular))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
            } trailing: {
                HStack(spacing: UIScale.pt(8)) {
                    if mode == .browse {
                        Button {
                            Task { await picker.goUp() }
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(QuinjetToolbarButtonStyle())
                        .disabled(FileListing.parentPath(of: picker.directory) == nil)
                        .help("Parent folder")
                    }
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(QuinjetToolbarButtonStyle())
                    .help(mode == .recent ? "Refresh recent projects" : "Refresh folder")
                }
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                    QuinjetMachineStrip(
                        machines: machines, selection: tab.machineID, select: selectMachine)
                    Picker("View", selection: $mode) {
                        ForEach(QuinjetMachinePickerMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if mode == .recent { searchField } else { pathField }
                }
            }

            Group {
                if mode == .recent { recentContent } else { browserContent }
            }
            .pageContent(compact)
        }
        .background(shortcuts)
    }

    private var searchField: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField("Search projects and worktrees", text: $model.query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, UIScale.pt(11))
        .frame(height: UIScale.pt(36))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .strokeBorder(DashSkin.lineStrong(dark))
        }
    }

    private var pathField: some View {
        HStack(spacing: UIScale.pt(9)) {
            Image(systemName: "folder")
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField(
                "Absolute folder path",
                text: Binding(get: { picker.path }, set: { picker.editPath($0) })
            )
            .textFieldStyle(.plain)
            .font(DashSkin.mono(10.5))
            .onKeyPress(.tab) {
                Task { await picker.completePath() }
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                picker.moveSelection(by: press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onKeyPress(.return) {
                activateSelection()
                return .handled
            }
            .onKeyPress { press in
                guard press.modifiers.contains(.command), press.key.character == "z" else {
                    return .ignored
                }
                Task { await picker.undoNavigation() }
                return .handled
            }
            if picker.loading {
                ProgressView()
                    .controlSize(.small)
            } else if !picker.canOpenCurrentDirectory, !picker.path.isEmpty {
                Text("matching")
                    .font(DashSkin.mono(8.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(.horizontal, UIScale.pt(11))
        .frame(height: UIScale.pt(36))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .strokeBorder(DashSkin.lineStrong(dark))
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        let projects = model.filteredProjects(for: remote)
        if model.isLoadingProjects(for: remote), projects.isEmpty {
            ProgressView("Loading recent projects from \(machine.name)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.projectError(for: remote), projects.isEmpty {
            ContentUnavailableView {
                Label("Projects unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await model.refreshProjects(for: remote) } }
                Button("Browse folders") { mode = .browse }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projects.isEmpty {
            ContentUnavailableView {
                Label(
                    model.query.isEmpty ? "No recent projects" : "No matching projects",
                    systemImage: "folder")
            } description: {
                Text("Browse a project folder on this machine to open it in Quinjet.")
            } actions: {
                Button("Browse folders") { mode = .browse }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: UIScale.pt(330)), spacing: UIScale.pt(14))
                    ], spacing: UIScale.pt(14)
                ) {
                    ForEach(projects) { project in
                        QuinjetProjectCard(
                            project: project,
                            open: { worktree in
                                model.open(
                                    worktree, projectName: project.name,
                                    available: project.availableWorktrees, remote: remote, in: tab,
                                    launchEnabled: launchEnabled, configuration: configuration)
                            })
                    }
                }
                .padding(.top, UIScale.pt(2))
            }
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if picker.loading, picker.directory.isEmpty {
            ProgressView("Connecting to \(machine.name)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = picker.errorMessage, picker.entries.isEmpty {
            ContentUnavailableView {
                Label("Folder unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await picker.start() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = tab.errorMessage {
            ContentUnavailableView {
                Label("Project unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Choose another folder") { tab.errorMessage = nil }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: UIScale.pt(5)) {
                    if picker.canOpenCurrentDirectory { currentDirectoryRow }
                    ForEach(picker.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.top, UIScale.pt(2))
            }
            .overlay {
                if picker.entries.isEmpty, !picker.loading, !picker.canOpenCurrentDirectory {
                    ContentUnavailableView(
                        "No matching folders", systemImage: "folder",
                        description: Text("Check the path or keep typing.")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var currentDirectoryRow: some View {
        Button {
            picker.selectCurrentDirectory()
            open(picker.directory)
        } label: {
            HStack(spacing: UIScale.pt(11)) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(DashSkin.accent(dark))
                    .frame(width: UIScale.pt(18))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Open this directory")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Text(picker.directory)
                        .font(DashSkin.mono(9))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("return")
                    .font(DashSkin.mono(8.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(minHeight: UIScale.pt(54))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuinjetFolderRowStyle(selected: picker.selectionIndex == -1, dark: dark))
    }

    private func entryRow(_ entry: RemoteFileEntry) -> some View {
        Button {
            if entry.isDirectory || entry.kind == .symlink {
                Task { await picker.navigate(to: entry.path) }
            } else {
                picker.select(entry)
            }
        } label: {
            HStack(spacing: UIScale.pt(11)) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(
                        entry.isDirectory ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                    )
                    .frame(width: UIScale.pt(18))
                Text(entry.name)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if picker.selectedEntry == entry {
                    Text("return")
                        .font(DashSkin.mono(8.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else if entry.isDirectory || entry.kind == .symlink {
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(minHeight: UIScale.pt(44))
            .contentShape(Rectangle())
        }
        .buttonStyle(
            QuinjetFolderRowStyle(selected: picker.selectedEntry == entry, dark: dark)
        )
    }

    private var shortcuts: some View {
        Button("") { Task { await picker.undoNavigation() } }
            .keyboardShortcut("z", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
    }

    private func activateSelection() {
        Task {
            if let path = await picker.activateSelection() { open(path) }
        }
    }

    private func open(_ path: String) {
        guard !path.isEmpty else { return }
        let session = machines.session(for: machine.id)
        guard session.state.isConnected else {
            Task { await picker.start() }
            return
        }
        Task {
            await model.openFolder(
                path, remote: remote, in: tab, launchEnabled: launchEnabled,
                configuration: configuration)
        }
    }

    private func refresh() {
        if mode == .recent {
            Task { await model.refreshProjects(for: remote) }
        } else {
            Task { await picker.refresh() }
        }
    }
}

struct QuinjetMachineStrip: View {
    let machines: MachinesModel
    let selection: UUID
    let select: (Machine) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(8)) {
                ForEach(machines.allMachines) { machine in
                    QuinjetMachineChip(
                        machine: machine, session: machines.session(for: machine.id),
                        selected: machine.id == selection,
                        local: machines.isLocal(machine.id), select: { select(machine) })
                }
            }
            .padding(.vertical, UIScale.pt(1))
        }
    }
}

private struct QuinjetMachineChip: View {
    let machine: Machine
    let session: MachineSession
    let selected: Bool
    let local: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button(action: select) {
            HStack(spacing: UIScale.pt(7)) {
                Circle()
                    .fill(statusColor)
                    .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    Text(machine.name)
                        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    Text(local ? "Local machine" : machine.subtitle)
                        .font(.system(size: UIScale.pt(8.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(34))
        }
        .buttonStyle(QuinjetMachineChipStyle(selected: selected, dark: dark))
    }

    private var statusColor: Color {
        if local || session.state.isConnected { return .green }
        if session.state.isBusy { return .orange }
        if session.state.failureMessage != nil { return .red }
        return DashSkin.inkFaint(dark)
    }
}

private struct QuinjetMachineChipStyle: ButtonStyle {
    let selected: Bool
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DashSkin.ink(dark))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.14) : DashSkin.paper2(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(
                        selected ? DashSkin.accent(dark).opacity(0.7) : DashSkin.lineStrong(dark))
            }
            .edithButtonTarget(.selection)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct QuinjetFolderRowStyle: ButtonStyle {
    let selected: Bool
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DashSkin.ink(dark))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.12) : DashSkin.paper2(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(
                        selected ? DashSkin.accent(dark).opacity(0.55) : DashSkin.lineStrong(dark))
            }
            .edithButtonTarget(.selection)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
