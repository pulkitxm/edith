import EdithExtensionSupport
import EdithExtensionUI
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

    private var machines: QuinjetMachines { model.machines }

    var body: some View {
        Group {
            if machines.isLocal(tab.machineID) {
                QuinjetLocalProjectPicker(
                    model: model, tab: tab, machines: machines, selectMachine: select)
            } else if let machine = selectedMachine, let picker = tab.folderPicker,
                let remote = tab.remote
            {
                QuinjetRemoteProjectPicker(
                    model: model, tab: tab, machines: machines, machine: machine, remote: remote,
                    picker: picker, selectMachine: select)
            } else if let machine = selectedMachine,
                let error = tab.folderPicker?.errorMessage ?? tab.errorMessage
            {
                PageEmptyState(
                    icon: .warning,
                    title: "\(machine.name) is not reachable",
                    message: "\(error) Nothing was changed on that machine.",
                    primary: PageAction("Try again", icon: .refresh) {
                        select(machine)
                    },
                    secondary: PageAction("Use this Mac", icon: .laptop) {
                        select(machines.localMachine)
                    })
            } else {
                QuinjetPreparingMachineSkeleton(
                    machines: machines, selection: tab.machineID,
                    machineName: selectedMachine?.name, selectMachine: select)
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
        if tab.folderPicker == nil || tab.remote == nil {
            select(machine)
        } else if let remote = tab.remote, model.projects(for: remote).isEmpty {
            QuinjetWorkOwnership.start { await model.refreshProjects(for: remote) }
        }
    }

    private func select(_ machine: Machine) {
        if model.isRemote { model.selectMachine(machine, in: tab); return }
        tab.machineID = machine.id
        tab.errorMessage = nil
        model.projectError = nil
        guard !machines.isLocal(machine.id) else {
            tab.folderPicker = nil
            tab.remote = nil
            if model.projects.isEmpty {
                QuinjetWorkOwnership.start { await model.refreshProjects() }
            }
            return
        }
        let picker = QuinjetFolderPickerModel(session: machines.session(for: machine.id))
        tab.folderPicker = picker
        tab.remote = nil
        QuinjetWorkOwnership.start {
            await picker.start()
            guard tab.machineID == machine.id, picker.errorMessage == nil else { return }
            let session = machines.session(for: machine.id)
            guard let connection = session.connectionRef else {
                tab.errorMessage = "The machine connection could not be prepared."
                return
            }
            do {
                let remote = try await QuinjetRemote.connected(
                    machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
                    connection: connection)
                guard tab.machineID == machine.id else { return }
                tab.remote = remote
                await model.refreshProjects(for: remote)
            } catch {
                guard tab.machineID == machine.id else { return }
                tab.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct QuinjetRemoteProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab
    let machines: QuinjetMachines
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
            PageHeader(
                "Open a project",
                subtitle: mode == .recent
                    ? "Recent Quinjet workspaces on \(machine.name)."
                    : "Browse live folders on \(machine.name)."
            ) {
                HStack(spacing: UIScale.pt(8)) {
                    if mode == .browse {
                        Button {
                            QuinjetWorkOwnership.start { await picker.goUp() }
                        } label: {
                            EdithIconView(.arrowUp)
                        }
                        .disabled(FileListing.parentPath(of: picker.directory) == nil)
                        .help("Parent folder")
                    }
                    Button {
                        refresh()
                    } label: {
                        EdithIconView(.refresh)
                    }
                    .help(mode == .recent ? "Refresh recent projects" : "Refresh folder")
                }
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    QuinjetMachineStrip(
                        machines: machines, selection: tab.machineID, select: selectMachine)
                    EdithSegmentedPicker(
                        "View", selection: $mode, options: QuinjetMachinePickerMode.allCases,
                        label: { $0.title }
                    )
                    .labelsHidden()
                    if mode == .recent { searchField } else { pathField }
                }
            }

            Group {
                if mode == .recent { recentContent } else { browserContent }
            }
        }
        .background(shortcuts)
    }

    private var searchField: some View {
        SearchField(placeholder: "Search projects and worktrees", text: $model.query)
    }

    private var pathField: some View {
        HStack(spacing: UIScale.pt(8)) {
            EdithIconView(.folder)
                .foregroundStyle(DashSkin.inkFaint(dark))
                .accessibilityHidden(true)
            TextField(
                "Absolute folder path",
                text: Binding(get: { picker.path }, set: { picker.editPath($0) })
            )
            .textFieldStyle(.plain)
            .font(.edithText(.callout, design: .monospaced))
            .onKeyPress(.tab) {
                QuinjetWorkOwnership.start { await picker.completePath() }
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
                QuinjetWorkOwnership.start { await picker.undoNavigation() }
                return .handled
            }
            if picker.loading {
                SkeletonGroup {
                    SkeletonBlock(width: 42, height: 8)
                }
                .accessibilityLabel("Matching folder path")
            } else if !picker.canOpenCurrentDirectory, !picker.path.isEmpty {
                Text("matching")
                    .font(.edithText(.caption2, design: .monospaced))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .edithFieldSurface(focused: false)
    }

    @ViewBuilder
    private var recentContent: some View {
        let projects = model.filteredProjects(for: remote)
        if model.isLoadingProjects(for: remote), projects.isEmpty {
            QuinjetProjectListSkeleton(dark: dark)
                .accessibilityLabel("Loading recent projects from \(machine.name)")
        } else if let error = model.projectError(for: remote), projects.isEmpty {
            PageEmptyState(
                icon: .warning,
                title: "Recent projects could not be loaded",
                message: "\(error) Nothing was changed on \(machine.name).",
                primary: PageAction("Try again", icon: .refresh) {
                    QuinjetWorkOwnership.start { await model.refreshProjects(for: remote) }
                },
                secondary: PageAction("Browse folders", icon: .folder) { mode = .browse })
        } else if projects.isEmpty {
            PageEmptyState(
                icon: .folder,
                title: model.query.isEmpty
                    ? "No recent projects on \(machine.name)" : "No project matches that search",
                message: model.query.isEmpty
                    ? "Browse the folders on \(machine.name) and pick a Git project to review. Opening a project only reads it."
                    : "Search looks at project names, branches and paths. Clear it to see every recent project.",
                primary: PageAction("Browse folders", icon: .folder) { mode = .browse },
                secondary: model.query.isEmpty
                    ? nil
                    : PageAction("Clear search", icon: .closeFilled) { model.query = "" })
        } else {
            ScrollView {
                QuinjetProjectList(projects: projects) { project, worktree in
                    model.open(
                        worktree, projectName: project.name,
                        available: project.availableWorktrees, remote: remote, in: tab,
                        launchEnabled: launchEnabled, configuration: configuration)
                }
                .padding(.top, UIScale.pt(2))
                .pageContent(compact)
            }
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if picker.loading, picker.directory.isEmpty {
            QuinjetFolderBrowserSkeleton(dark: dark)
                .accessibilityLabel("Connecting to \(machine.name)")
        } else if let error = picker.errorMessage, picker.entries.isEmpty {
            PageEmptyState(
                icon: .warning,
                title: "Folders could not be listed",
                message: "\(error) Nothing was changed on \(machine.name).",
                primary: PageAction("Try again", icon: .refresh) {
                    QuinjetWorkOwnership.start { await picker.start() }
                })
        } else if let error = tab.errorMessage {
            PageEmptyState(
                icon: .warning,
                title: "That folder could not be opened",
                message: "\(error) Pick a different folder, ideally one that is a Git project.",
                primary: PageAction("Choose another folder", icon: .folder) {
                    tab.errorMessage = nil
                })
        } else {
            ScrollView {
                LazyVStack(spacing: UIScale.pt(5)) {
                    if picker.canOpenCurrentDirectory { currentDirectoryRow }
                    ForEach(picker.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.top, UIScale.pt(2))
                .pageContent(compact)
            }
            .overlay {
                if picker.entries.isEmpty, !picker.loading, !picker.canOpenCurrentDirectory {
                    ContentStatusView(
                        "No matching folders", message: "Check the path or keep typing.",
                        icon: .folder
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
                EdithIconView(.arrowTurn)
                    .foregroundStyle(DashSkin.accent(dark))
                    .frame(width: UIScale.pt(18))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Open this directory")
                        .font(.edithText(.headline))
                    Text(picker.directory)
                        .font(.edithText(.caption, design: .monospaced))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("return")
                    .font(.edithText(.caption2, design: .monospaced))
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
                QuinjetWorkOwnership.start { await picker.navigate(to: entry.path) }
            } else {
                picker.select(entry)
            }
        } label: {
            HStack(spacing: UIScale.pt(11)) {
                EdithIconView(entry.isDirectory ? .folder : .doc)
                    .foregroundStyle(
                        entry.isDirectory ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                    )
                    .frame(width: UIScale.pt(18))
                Text(entry.name)
                    .font(.edithText(.callout).weight(.medium))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if picker.selectedEntry == entry {
                    Text("return")
                        .font(.edithText(.caption2, design: .monospaced))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else if entry.isDirectory || entry.kind == .symlink {
                    EdithIconView(.chevronRight)
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
        Button("") { QuinjetWorkOwnership.start { await picker.undoNavigation() } }
            .keyboardShortcut("z", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
    }

    private func activateSelection() {
        QuinjetWorkOwnership.start {
            if let path = await picker.activateSelection() { open(path) }
        }
    }

    private func open(_ path: String) {
        guard !path.isEmpty else { return }
        let session = machines.session(for: machine.id)
        guard session.state.isConnected else {
            QuinjetWorkOwnership.start { await picker.start() }
            return
        }
        QuinjetWorkOwnership.start {
            await model.openFolder(
                path, remote: remote, in: tab, launchEnabled: launchEnabled,
                configuration: configuration)
        }
    }

    private func refresh() {
        if mode == .recent {
            QuinjetWorkOwnership.start { await model.refreshProjects(for: remote) }
        } else {
            QuinjetWorkOwnership.start { await picker.refresh() }
        }
    }
}

private struct QuinjetPreparingMachineSkeleton: View {
    let machines: QuinjetMachines
    let selection: UUID
    let machineName: String?
    let selectMachine: (Machine) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                "Open a project",
                subtitle: "Recent Quinjet workspaces on \(machineName ?? "this machine")."
            ) {
                SkeletonGroup {
                    SkeletonBlock(width: 30, height: 30, corner: 7)
                }
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    QuinjetMachineStrip(
                        machines: machines, selection: selection, select: selectMachine)
                    SkeletonGroup {
                        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                            HStack(spacing: UIScale.pt(2)) {
                                SkeletonBlock(height: 24, corner: 6)
                                SkeletonBlock(height: 24, corner: 6)
                            }
                            HStack(spacing: UIScale.pt(8)) {
                                SkeletonBlock(width: 14, height: 14, corner: 7)
                                SkeletonBlock(width: 186, height: 10)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, UIScale.pt(11))
                            .frame(height: UIScale.pt(36))
                            .background(
                                DashSkin.paper2(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: UIScale.pt(8))
                                    .strokeBorder(DashSkin.lineStrong(dark))
                            }
                        }
                    }
                }
            }
            QuinjetProjectListSkeleton(dark: dark)
                .pageContent(compact)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing machine")
    }
}

struct QuinjetMachineStrip: View {
    let machines: QuinjetMachines
    let selection: UUID
    let select: (Machine) -> Void

    private var recentMachines: [Machine] {
        LauncherUsage.shared.ordered(machines.allMachines) {
            ["machine", machines.isLocal($0.id) ? "local" : $0.id.uuidString]
        }
    }

    var body: some View {
        if machines.allMachines.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                    ForEach(recentMachines) { machine in
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
}

private struct QuinjetMachineChip: View {
    let machine: Machine
    let session: QuinjetMachineSession
    let selected: Bool
    let local: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PageChip(machine.name, dot: statusColor, active: selected, action: select)
            .help(local ? "This Mac" : machine.subtitle)
    }

    private var statusColor: Color {
        if local || session.state.isConnected { return .green }
        if session.state.isBusy { return .orange }
        if session.state.failureMessage != nil { return .red }
        return DashSkin.inkFaint(scheme == .dark)
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
            .edithHoverHighlight(
                tone: .neutral, cornerRadius: UIScale.pt(8), pressed: configuration.isPressed
            )
            .edithButtonTarget(.selection)
    }
}
