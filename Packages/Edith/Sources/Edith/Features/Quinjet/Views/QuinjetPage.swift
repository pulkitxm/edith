import EdithKit
import SwiftUI

struct QuinjetPage: View {
    @State private var model = QuinjetPageModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

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
        .task {
            guard automaticActionsEnabled else { return }
            await model.refreshProjects()
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
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(9))
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func tabContent(_ tab: QuinjetTab) -> some View {
        if tab.worktree == nil {
            QuinjetProjectPicker(model: model, tab: tab)
        } else {
            QuinjetTerminalWorkspace(model: model, tab: tab)
        }
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

    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

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
            TerminalPane(holder: tab.holder, dark: dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(dark ? Color.black.opacity(0.9) : Color.white)
    }

    private var workspaceBar: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "laptopcomputer")
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
                        launchEnabled: launchEnabled)
                })
        }
    }

    private var worktreeCount: String {
        let count = tab.worktrees.count
        return count == 1 ? "1 worktree" : "\(count) worktrees"
    }

    private func restart() {
        guard let worktree = tab.worktree else { return }
        model.open(
            worktree, projectName: tab.projectName ?? "Project", available: tab.worktrees,
            remote: tab.remote, in: tab, launchEnabled: launchEnabled)
    }
}
