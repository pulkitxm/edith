import EdithKit
import SwiftUI

struct QuinjetProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab

    @State private var machines = MachinesModel.shared

    var body: some View {
        Group {
            if machines.isLocal(tab.machineID) {
                QuinjetLocalProjectPicker(
                    model: model, tab: tab, machines: machines, selectMachine: select)
            } else if let machine = selectedMachine, let picker = tab.folderPicker {
                QuinjetRemoteProjectPicker(
                    model: model, tab: tab, machines: machines, machine: machine,
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
        if !machines.isLocal(machine.id), tab.folderPicker == nil { select(machine) }
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
        Task { await picker.start() }
    }
}

private struct QuinjetRemoteProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab
    let machines: MachinesModel
    let machine: Machine
    @Bindable var picker: QuinjetFolderPickerModel
    let selectMachine: (Machine) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Open a project")
                    Text("Browse live folders on \(machine.name)")
                        .font(.system(size: UIScale.pt(12), weight: .regular))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            } trailing: {
                HStack(spacing: UIScale.pt(8)) {
                    Button {
                        Task { await picker.goUp() }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(QuinjetToolbarButtonStyle())
                    .disabled(picker.directory == "/" || picker.directory.isEmpty)
                    .help("Parent folder")
                    Button {
                        Task { await picker.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(QuinjetToolbarButtonStyle())
                    .help("Refresh folder")
                }
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                    QuinjetMachineStrip(
                        machines: machines, selection: tab.machineID, select: selectMachine)
                    pathField
                }
            }

            content
                .pageContent(compact)
        }
        .background(shortcuts)
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
    private var content: some View {
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
        } else {
            ScrollView {
                LazyVStack(spacing: UIScale.pt(5)) {
                    currentDirectoryRow
                    ForEach(picker.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.top, UIScale.pt(2))
            }
            .overlay {
                if picker.entries.isEmpty, !picker.loading {
                    ContentUnavailableView(
                        "No matching folders", systemImage: "folder",
                        description: Text("Edit the path or open the current directory.")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var currentDirectoryRow: some View {
        Button {
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
        .pointerCursor()
        .simultaneousGesture(TapGesture().onEnded { picker.selectCurrentDirectory() })
    }

    private func entryRow(_ entry: RemoteFileEntry) -> some View {
        Button {
            picker.select(entry)
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
                if entry.isDirectory || entry.kind == .symlink {
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
        .pointerCursor()
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard entry.isDirectory || entry.kind == .symlink else { return }
                Task { await picker.navigate(to: entry.path) }
            })
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
        guard session.state.isConnected, let connection = session.connectionRef else {
            Task { await picker.start() }
            return
        }
        let remote = QuinjetRemote(
            machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
            controlPath: connection.controlSocketPath)
        Task {
            await model.openFolder(
                path, remote: remote, in: tab, launchEnabled: launchEnabled)
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
        .pointerCursor()
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
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
