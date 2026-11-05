import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct QuinjetLocalProjectPicker: View {
    @Bindable var model: QuinjetPageModel
    let tab: QuinjetTab
    let machines: QuinjetMachines
    let selectMachine: (Machine) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @Environment(\.quinjetLaunchConfiguration) private var configuration

    private var dark: Bool { scheme == .dark }

    static let firstRunSteps = [
        PageGuideStep(
            symbolName: "folder", title: "Pick a Git project",
            detail: "Choose a folder or one of your recent projects."),
        PageGuideStep(
            symbolName: "arrow.triangle.branch", title: "Choose a worktree",
            detail: "Each branch checkout gets its own review session."),
        PageGuideStep(
            symbolName: "terminal", title: "Review in the terminal",
            detail: "Quinjet starts in the folder and you review from there."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                "Open a project",
                subtitle: model.projects.isEmpty
                    ? "Choose a Git project to review."
                    : "Choose a Git project to review. Recent ones from this Mac are listed below."
            ) {
                HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                    if !model.projects.isEmpty {
                        Button(action: chooseFolder) {
                            Label("Choose folder", systemImage: "folder.badge.plus")
                        }
                    }
                    PageToolbarButton(
                        action: { QuinjetWorkOwnership.start { await model.refreshProjects() } },
                        systemImage: "arrow.clockwise", helperText: "Refresh recent projects")
                }
            } accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    QuinjetMachineStrip(
                        machines: machines, selection: tab.machineID, select: selectMachine)
                    if !model.projects.isEmpty {
                        SearchField(
                            placeholder: "Search projects and worktrees", text: $model.query)
                    }
                }
            }

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loadingProjects, model.projects.isEmpty {
            QuinjetProjectGridSkeleton(dark: dark)
        } else if model.projectError == QuinjetClientError.notInstalled.errorDescription,
            model.projects.isEmpty
        {
            PageEmptyState(
                symbolName: "arrow.down.circle",
                title: "Install the Quinjet tool first",
                message:
                    "This page drives the quinjet command line tool, which is not on this Mac yet. Installing it adds one command and does not touch your projects.",
                steps: [
                    PageGuideStep(
                        symbolName: "terminal", title: "Run one command",
                        detail: "Run ed tools install quinjet in a terminal."),
                    PageGuideStep(
                        symbolName: "arrow.clockwise", title: "Check again",
                        detail: "Come back here and press Check again."),
                ],
                primary: PageAction("Check again", symbolName: "arrow.clockwise") {
                    QuinjetWorkOwnership.start { await model.refreshProjects() }
                },
                footnote: "Prefer Homebrew? Run brew install pulkitxm/tap/quinjet.")
        } else if let error = model.projectError, model.projects.isEmpty {
            PageEmptyState(
                symbolName: "exclamationmark.triangle",
                title: "Recent projects could not be loaded",
                message:
                    "\(error) Your projects were not changed. You can retry, or pick a folder yourself.",
                primary: PageAction("Try again", symbolName: "arrow.clockwise") {
                    QuinjetWorkOwnership.start { await model.refreshProjects() }
                },
                secondary: PageAction(
                    "Choose folder", symbolName: "folder.badge.plus", perform: chooseFolder))
        } else if model.filteredProjects.isEmpty, !model.query.isEmpty {
            PageEmptyState(
                symbolName: "magnifyingglass",
                title: "No project matches \u{201C}\(model.query)\u{201D}",
                message:
                    "Search looks at project names, branches and paths. Clear the search to see every recent project.",
                primary: PageAction("Clear search", symbolName: "xmark.circle") {
                    model.query = ""
                },
                secondary: PageAction(
                    "Choose folder", symbolName: "folder.badge.plus", perform: chooseFolder))
        } else if model.filteredProjects.isEmpty {
            PageEmptyState(
                symbolName: "arrow.triangle.branch",
                title: "Review code with an AI agent, side by side",
                message:
                    "Quinjet opens a Git project in a terminal built for reviewing pull requests and changes. Pick a project to begin.",
                steps: Self.firstRunSteps,
                primary: PageAction(
                    "Choose folder", symbolName: "folder.badge.plus", perform: chooseFolder),
                footnote:
                    "Opening a project only reads it. Nothing is changed until you act in the terminal."
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: PageMetrics.cardColumns(
                        compact, minimum: 330, spacing: PageMetrics.cardSpacing),
                    spacing: UIScale.pt(PageMetrics.cardSpacing)
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
                .pageContent(compact)
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
        QuinjetWorkOwnership.start {
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
                HStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: UIScale.pt(18), weight: .medium))
                        .foregroundStyle(DashSkin.accent(dark))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(project.name)
                            .font(.edithText(.headline))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        Text(project.defaultWorktree?.path ?? project.commonDir)
                            .font(.edithText(.caption, design: .monospaced))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))

            Button {
                showsWorktrees = true
            } label: {
                VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                    Text(worktreeCount)
                        .font(.edithText(.callout).weight(.semibold))
                    Text("opened recently")
                        .font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .padding(.horizontal, UIScale.pt(12))
                .padding(.vertical, UIScale.pt(8))
            }
            .buttonStyle(QuinjetWorktreeCountButtonStyle(dark: dark))
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
        .padding(UIScale.pt(PageMetrics.cardPadding))
        .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
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
                    .font(.edithText(.headline))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(worktreeCount)
                    .font(.edithText(.caption))
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
                        .frame(width: UIScale.pt(16))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(worktree.displayName)
                                .font(.edithText(.callout).weight(.semibold))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(worktree.path)
                                .font(.edithText(.caption2, design: .monospaced))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(8))
                    .frame(minHeight: UIScale.pt(44))
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuinjetWorktreeRowStyle(dark: dark))
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
                in: RoundedRectangle(
                    cornerRadius: UIScale.pt(PageMetrics.chipCornerRadius), style: .continuous)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: UIScale.pt(PageMetrics.chipCornerRadius), style: .continuous
                )
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
