import EdithKit
import SwiftUI

struct QuinjetPage: View {
    @State private var model = QuinjetPageModel()
    @AppStorage(AppStorageKeys.Quinjet.terminal, store: SharedDefaults.store)
    private var terminalName = QuinjetTerminal.embedded.rawValue
    @AppStorage(AppStorageKeys.Quinjet.theme, store: SharedDefaults.store)
    private var themeName = QuinjetTheme.quinjet.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.45)
            ZStack {
                ForEach(model.tabs) { tab in
                    tabContent(tab)
                        .opacity(tab.id == model.selected ? 1 : 0)
                        .allowsHitTesting(tab.id == model.selected)
                }
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .environment(\.quinjetLaunchConfiguration, configuration)
        .task {
            guard automaticActionsEnabled else { return }
            await model.refreshProjects()
        }
        .onChange(of: configuration) { _, configuration in
            model.apply(configuration, launchEnabled: launchEnabled)
        }
        .onDisappear { model.stopAll() }
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(5)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(4)) {
                    ForEach(model.tabs) { tab in
                        QuinjetTabButton(
                            tab: tab, selected: tab.id == model.selected,
                            canClose: model.tabs.count > 1,
                            select: { model.selected = tab.id }, close: { model.close(tab) })
                    }
                }
            }
            Button {
                model.addPickerTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(HoverButtonStyle())
            .pointerCursor()
            .help("New Quinjet review")
            terminalMenu
            themeMenu
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(9))
        .background(.thinMaterial)
    }

    private var configuration: QuinjetLaunchConfiguration {
        let storedTerminal = QuinjetTerminal(rawValue: terminalName) ?? .embedded
        return QuinjetLaunchConfiguration(
            terminal: storedTerminal.isAvailable ? storedTerminal : .embedded,
            theme: QuinjetTheme(rawValue: themeName) ?? .quinjet,
            appearance: scheme == .dark ? .dark : .light)
    }

    private var terminalMenu: some View {
        Menu {
            ForEach(QuinjetTerminal.allCases) { terminal in
                Button {
                    terminalName = terminal.rawValue
                } label: {
                    if terminal == configuration.terminal {
                        Label(terminal.label, systemImage: "checkmark")
                    } else {
                        Label(terminal.label, systemImage: terminal.icon)
                    }
                }
                .disabled(!terminal.isAvailable)
            }
        } label: {
            QuinjetMenuLabel(
                icon: configuration.terminal.icon, title: configuration.terminal.label)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Terminal renderer")
    }

    private var themeMenu: some View {
        Menu {
            ForEach(QuinjetTheme.allCases) { theme in
                Button {
                    themeName = theme.rawValue
                } label: {
                    if theme == configuration.theme {
                        Label(theme.label, systemImage: "checkmark")
                    } else {
                        Text(theme.label)
                    }
                }
            }
        } label: {
            QuinjetMenuLabel(icon: "paintpalette", title: configuration.theme.label)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Quinjet theme")
    }

    @ViewBuilder
    private func tabContent(_ tab: QuinjetTab) -> some View {
        if tab.worktree == nil {
            QuinjetProjectPicker(model: model, tab: tab)
        } else {
            QuinjetTerminalWorkspace(
                model: model, tab: tab,
                useEmbedded: { terminalName = QuinjetTerminal.embedded.rawValue })
        }
    }
}

private struct QuinjetMenuLabel: View {
    let icon: String
    let title: String
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: icon)
                .font(.system(size: UIScale.pt(10), weight: .semibold))
            Text(title)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: UIScale.pt(7), weight: .bold))
        }
        .foregroundStyle(DashSkin.ink(dark))
        .padding(.horizontal, UIScale.pt(9))
        .padding(.vertical, UIScale.pt(6))
        .background(
            hovered ? DashSkin.inkFaint(dark).opacity(0.12) : DashSkin.paper2(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(6))
                .stroke(DashSkin.lineStrong(dark), lineWidth: UIScale.pt(1))
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .pointerCursor()
    }
}

private struct QuinjetTabButton: View {
    let tab: QuinjetTab
    let selected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button(action: select) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: tab.worktree == nil ? "plus.square" : "arrow.triangle.branch")
                    .font(.system(size: UIScale.pt(9.5)))
                Text(tab.title)
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .lineLimit(1)
                if canClose {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: UIScale.pt(7.5), weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(6))
            .background(
                selected ? DashSkin.paper2(dark) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

private struct QuinjetTerminalWorkspace: View {
    let model: QuinjetPageModel
    @Bindable var tab: QuinjetTab
    let useEmbedded: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled
    @Environment(\.quinjetLaunchConfiguration) private var configuration

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            workspaceBar
            if let error = tab.errorMessage {
                HStack(spacing: UIScale.pt(7)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                    Spacer(minLength: 0)
                }
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.warn)
                .padding(.horizontal, PageMetrics.gutter(compact))
                .padding(.vertical, UIScale.pt(7))
                .background(DashSkin.warn.opacity(0.1))
            }
            if tab.launchConfiguration.terminal == .embedded {
                TerminalPane(
                    holder: tab.holder,
                    palette: .quinjet(
                        theme: tab.launchConfiguration.theme,
                        appearance: tab.launchConfiguration.appearance)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                externalWorkspace
            }
        }
        .background(dark ? Color.black.opacity(0.9) : Color.white)
    }

    private var workspaceBar: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: tab.launchConfiguration.terminal.icon)
                .foregroundStyle(DashSkin.inkFaint(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(tab.title)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(tab.worktree?.path ?? "")
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let message = tab.holder.exitMessage {
                Text(message)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.warn)
                Button("Restart", action: restart)
                    .buttonStyle(.plain)
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .pointerCursor()
            }
            if let message = tab.externalLaunchMessage {
                Text(message)
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Button {
                Task { await model.presentWorktrees(for: tab) }
            } label: {
                Text(worktreeCount)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .padding(.horizontal, UIScale.pt(11))
                    .padding(.vertical, UIScale.pt(7))
            }
            .buttonStyle(QuinjetWorktreeCountButtonStyle(dark: dark))
            .pointerCursor()
            .popover(isPresented: $tab.showsWorktrees, arrowEdge: .bottom) {
                worktreePopover
            }
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.vertical, UIScale.pt(9))
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var worktreePopover: some View {
        if tab.loadingWorktrees {
            ProgressView("Loading worktrees")
                .padding(UIScale.pt(28))
                .frame(width: UIScale.pt(300))
        } else if let error = tab.errorMessage, tab.worktrees.isEmpty {
            ContentUnavailableView(
                "Worktrees unavailable", systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .padding(UIScale.pt(16))
            .frame(width: UIScale.pt(360), height: UIScale.pt(220))
        } else {
            QuinjetWorktreePicker(
                projectName: tab.projectName ?? "Project", worktrees: tab.worktrees,
                selectedPath: tab.worktree?.path,
                select: { worktree in
                    model.open(
                        worktree, projectName: tab.projectName ?? "Project",
                        available: tab.worktrees, remote: tab.remote, in: tab,
                        launchEnabled: launchEnabled, configuration: configuration)
                })
        }
    }

    private var worktreeCount: String {
        let count = tab.worktrees.count
        return count == 1 ? "1 worktree" : "\(count) worktrees"
    }

    private var externalWorkspace: some View {
        let palette = TerminalPalette.quinjet(
            theme: tab.launchConfiguration.theme,
            appearance: tab.launchConfiguration.appearance)
        return ZStack {
            Color(nsColor: palette.background)
            VStack(spacing: UIScale.pt(18)) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: UIScale.pt(30), weight: .medium))
                    .foregroundStyle(Color(nsColor: palette.caret))
                VStack(spacing: UIScale.pt(6)) {
                    Text("Open in cmux")
                        .font(.system(size: UIScale.pt(22), weight: .bold))
                    Text(tab.title)
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Text(tab.worktree?.path ?? "")
                        .font(DashSkin.mono(10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color(nsColor: palette.foreground))
                HStack(spacing: UIScale.pt(10)) {
                    Button("Show in cmux", action: restart)
                        .buttonStyle(QuinjetToolbarButtonStyle())
                        .pointerCursor()
                    Button("Use embedded terminal", action: useEmbedded)
                        .buttonStyle(QuinjetToolbarButtonStyle())
                        .pointerCursor()
                }
                Text("Theme: \(tab.launchConfiguration.theme.label)")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.65))
            }
            .padding(UIScale.pt(30))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func restart() {
        guard let worktree = tab.worktree else { return }
        model.open(
            worktree, projectName: tab.projectName ?? "Project", available: tab.worktrees,
            remote: tab.remote, in: tab, launchEnabled: launchEnabled,
            configuration: configuration)
    }
}
