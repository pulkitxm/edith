import AppKit
import EdithKit
import SwiftUI

struct QuinjetLocalProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab
    let machines: MachinesModel
    let selectMachine: (Machine) -> Void

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
                    Text("Recent workspaces on this Mac")
                        .font(.system(size: UIScale.pt(12), weight: .regular))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            } trailing: {
                HStack(spacing: UIScale.pt(8)) {
                    Button(action: chooseFolder) {
                        Label("Choose folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(QuinjetToolbarButtonStyle())
                    .pointerCursor()
                    Button {
                        Task { await model.refreshProjects() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(QuinjetToolbarButtonStyle())
                    .pointerCursor()
                    .help("Refresh recent projects")
                }
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                    QuinjetMachineStrip(
                        machines: machines, selection: tab.machineID, select: selectMachine)
                    HStack(spacing: UIScale.pt(8)) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        TextField("Search projects and worktrees", text: $model.query)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, UIScale.pt(11))
                    .frame(height: UIScale.pt(34))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(8))
                            .strokeBorder(DashSkin.lineStrong(dark))
                    }
                }
            }

            content
                .pageContent(compact)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loadingProjects, model.projects.isEmpty {
            ProgressView("Loading recent projects")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.projectError, model.projects.isEmpty {
            ContentUnavailableView {
                Label("Projects unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Choose folder", action: chooseFolder)
                Button("Try again") { Task { await model.refreshProjects() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredProjects.isEmpty {
            ContentUnavailableView {
                Label(
                    model.query.isEmpty ? "No recent projects" : "No matching projects",
                    systemImage: "folder")
            } description: {
                Text(
                    model.query.isEmpty
                        ? "Choose a Git project to open it in Quinjet."
                        : "Try a project name, branch, or path.")
            } actions: {
                Button("Choose folder", action: chooseFolder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: UIScale.pt(330)), spacing: UIScale.pt(14))
                    ],
                    spacing: UIScale.pt(14)
                ) {
                    ForEach(model.filteredProjects) { project in
                        QuinjetProjectCard(
                            project: project,
                            open: { worktree in
                                model.open(
                                    worktree, projectName: project.name,
                                    available: project.availableWorktrees, in: tab,
                                    launchEnabled: launchEnabled, configuration: configuration)
                            })
                    }
                }
                .padding(.top, UIScale.pt(2))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open in Quinjet"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        Task {
            await model.openFolder(
                path, in: tab, launchEnabled: launchEnabled, configuration: configuration)
        }
    }
}

struct QuinjetProjectCard: View {
    let project: QuinjetProject
    let open: (QuinjetWorktree) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var showsWorktrees = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(12)) {
            Button {
                if let worktree = project.defaultWorktree { open(worktree) }
            } label: {
                HStack(spacing: UIScale.pt(11)) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: UIScale.pt(18), weight: .medium))
                        .foregroundStyle(DashSkin.accent(dark))
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(project.name)
                            .font(.system(size: UIScale.pt(14), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(project.defaultWorktree?.path ?? project.commonDir)
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .pointerCursor()

            Button {
                showsWorktrees = true
            } label: {
                VStack(alignment: .trailing, spacing: UIScale.pt(4)) {
                    Text(worktreeCount)
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                    Text("opened recently")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .frame(minWidth: UIScale.pt(118), alignment: .trailing)
                .padding(.horizontal, UIScale.pt(12))
                .padding(.vertical, UIScale.pt(10))
            }
            .buttonStyle(QuinjetWorktreeCountButtonStyle(dark: dark))
            .pointerCursor()
            .popover(isPresented: $showsWorktrees, arrowEdge: .bottom) {
                QuinjetWorktreePicker(
                    projectName: project.name, worktrees: project.availableWorktrees,
                    selectedPath: nil,
                    select: {
                        open($0)
                        showsWorktrees = false
                    })
            }
        }
        .padding(UIScale.pt(14))
        .background(
            DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .strokeBorder(DashSkin.lineStrong(dark))
        }
    }

    private var worktreeCount: String {
        let count = project.availableWorktrees.count
        return count == 1 ? "1 worktree" : "\(count) worktrees"
    }
}

struct QuinjetWorktreePicker: View {
    let projectName: String
    let worktrees: [QuinjetWorktree]
    let selectedPath: String?
    let select: (QuinjetWorktree) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var availableWorktrees: [QuinjetWorktree] { worktrees.filter(\.canOpen) }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(8)) {
                Text(projectName)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(worktreeCount)
                    .font(DashSkin.mono(9.5, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Divider().opacity(0.5)
            if availableWorktrees.count > 5 {
                ScrollView { rows }
                    .frame(height: UIScale.pt(250))
            } else {
                rows
            }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(330))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rows: some View {
        LazyVStack(spacing: UIScale.pt(3)) {
            ForEach(availableWorktrees) { worktree in
                Button {
                    select(worktree)
                } label: {
                    HStack(spacing: UIScale.pt(9)) {
                        Image(
                            systemName: selectedPath == worktree.path
                                ? "checkmark.circle.fill" : "arrow.triangle.branch"
                        )
                        .font(.system(size: UIScale.pt(11), weight: .medium))
                        .foregroundStyle(
                            selectedPath == worktree.path
                                ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                        )
                        .frame(width: UIScale.pt(15))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(worktree.displayName)
                                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(worktree.path)
                                .font(DashSkin.mono(8.5))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(7))
                    .frame(minHeight: UIScale.pt(42))
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuinjetWorktreeRowStyle(dark: dark))
                .pointerCursor()
            }
        }
    }

    private var worktreeCount: String {
        let count = availableWorktrees.count
        return count == 1 ? "1 worktree" : "\(count) worktrees"
    }
}

struct QuinjetWorktreeCountButtonStyle: ButtonStyle {
    let dark: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? DashSkin.accent(dark) : DashSkin.ink(dark))
            .background(
                hovering
                    ? DashSkin.accent(dark).opacity(dark ? 0.2 : 0.13)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(9))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(9))
                    .strokeBorder(
                        hovering ? DashSkin.accent(dark).opacity(0.65) : DashSkin.lineStrong(dark))
            }
            .edithButtonTarget(.toolbar)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovering = $0 }
    }
}

private struct QuinjetWorktreeRowStyle: ButtonStyle {
    let dark: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovering
                    ? DashSkin.accent(dark).opacity(dark ? 0.14 : 0.1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(
                        hovering ? DashSkin.accent(dark).opacity(0.3) : Color.clear)
            }
            .edithButtonTarget(.row)
            .onHover { hovering = $0 }
    }
}

struct QuinjetToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        configuration.label
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(30))
            .background(
                hovering ? DashSkin.inkFaint(dark).opacity(0.12) : DashSkin.paper2(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(DashSkin.lineStrong(dark))
            }
            .edithButtonTarget(.toolbar)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovering = $0 }
    }
}
