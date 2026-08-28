import AppKit
import EdithKit
import SwiftUI

struct TerminalSettingsPane: View {
    @AppStorage(CompletionScripts.autoRefreshKey, store: SharedDefaults.store)
    private var autoRefresh = true
    @State private var tools = CLIToolStatus(directory: "")
    @State private var completions: [CompletionStatus] = []
    @State private var sourceLine = ""
    @State private var loaded = false
    @State private var running: TerminalAction?
    @State private var outcome: ActionOutcome?
    @State private var outcomeStamp = 0
    @Environment(\.terminalLaunchEnabled) private var terminalLaunchEnabled

    var body: some View {
        Form {
            toolsSection
            completionSection
            fallbackSection
            launchSection
        }
        .formStyle(.grouped)
        .navigationTitle("Terminal")
        .task {
            if terminalLaunchEnabled { await refresh() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if terminalLaunchEnabled { Task { await refresh() } }
        }
    }

    private var toolsSection: some View {
        Section {
            LabeledContent("Tools") {
                if loaded {
                    Text(toolSummary).foregroundStyle(.secondary)
                } else {
                    CheckingLabel("Checking...")
                }
            }
            LabeledContent("Location") {
                if loaded {
                    Text(tools.directory.isEmpty ? "-" : abbreviate(tools.directory))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    CheckingLabel("Checking...")
                }
            }
            HStack(spacing: UIScale.pt(10)) {
                ActionButton(
                    idle: loaded && tools.isComplete ? "Reinstall" : "Install",
                    running: loaded && tools.isComplete ? "Reinstalling..." : "Installing...",
                    done: "Installed",
                    phase: phase(of: .installTools),
                    enabled: idle && loaded && tools.bundled
                ) { run(.installTools) }
                ActionButton(
                    idle: "Remove", running: "Removing...", done: "Removed",
                    phase: phase(of: .removeTools),
                    enabled: idle && loaded && !tools.linked.isEmpty
                ) { run(.removeTools) }
            }
        } header: {
            Text("Command line tools")
        } footer: {
            SectionFooter(
                help: toolsHelp, outcome: footerOutcome(for: [.installTools, .removeTools]))
        }
    }

    private var completionSection: some View {
        Section {
            if !loaded {
                CheckingLabel("Looking for shells...")
            } else if completions.isEmpty {
                Text("No shells found.").foregroundStyle(.secondary)
            } else {
                ForEach(completions, id: \.shell) { status in
                    completionRow(status)
                }
            }
            ActionButton(
                idle: "Install completions", running: "Writing scripts...", done: "Installed",
                phase: phase(of: .installCompletions),
                enabled: idle && loaded
            ) { run(.installCompletions) }
        } header: {
            Text("Shell completion")
        } footer: {
            SectionFooter(
                help:
                    "A shell reads its completions once, when it starts. Run  exec zsh  in a terminal you already have open, or open a new tab.",
                outcome: footerOutcome(for: [.installCompletions]))
        }
    }

    private var fallbackSection: some View {
        Section {
            if loaded {
                Text(sourceLine)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .textSelection(.enabled)
            } else {
                CheckingLabel("Working out the path...")
            }
            ActionButton(
                idle: "Copy", running: "Copy", done: "Copied",
                phase: phase(of: .copySourceLine),
                enabled: loaded && !sourceLine.isEmpty
            ) { run(.copySourceLine) }
            if let hint = completions.compactMap(\.hint).first {
                Text(hint)
                    .settingsCaption()
                    .textSelection(.enabled)
            }
        } header: {
            Text("If a shell still does not complete")
        } footer: {
            SectionFooter(
                help:
                    "Adding this to ~/.zshrc loads the completion directly, the way the ac CLI does, instead of waiting for compinit to find it.",
                outcome: footerOutcome(for: [.copySourceLine]))
        }
    }

    private var launchSection: some View {
        Section {
            Toggle(isOn: $autoRefresh.configured(CompletionScripts.autoRefreshKey)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Keep completions up to date")
                    InfoDot(
                        "Rewrites the completion script when Edith starts, so an update never leaves an old one behind. Only touches a file Edith wrote."
                    )
                }
            }
        } header: {
            Text("On launch")
        }
    }

    private func completionRow(_ status: CompletionStatus) -> some View {
        LabeledContent(status.shell.rawValue) {
            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                HStack(spacing: UIScale.pt(6)) {
                    Circle()
                        .fill(color(for: status.state))
                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                    Text(label(for: status.state)).foregroundStyle(.secondary)
                }
                Text(abbreviate(status.path.path))
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func label(for state: CompletionInstallState) -> String {
        switch state {
        case .current: return "up to date"
        case .outdated: return "out of date"
        case .missing: return "not installed"
        case .foreign: return "not ours, left alone"
        }
    }

    private func color(for state: CompletionInstallState) -> Color {
        switch state {
        case .current: return .green
        case .outdated: return .orange
        case .missing: return .secondary
        case .foreign: return .yellow
        }
    }

    private var idle: Bool { running == nil }

    private func phase(of action: TerminalAction) -> ActionPhase {
        if running == action { return .running }
        guard let outcome, outcome.action == action else { return .idle }
        return outcome.succeeded ? .done : .failed
    }

    private func footerOutcome(for actions: [TerminalAction]) -> ActionOutcome? {
        guard let outcome, actions.contains(outcome.action) else { return nil }
        return outcome
    }

    private var toolsHelp: String {
        if !loaded { return "ed and edith are the same tool under two names." }
        if !tools.bundled { return "This build does not carry the ed binary." }
        if !tools.onPath, !tools.directory.isEmpty {
            return
                "\(abbreviate(tools.directory)) is not on your PATH, so the shell cannot find ed yet."
        }
        return "ed and edith are the same tool under two names."
    }

    private var toolSummary: String {
        guard tools.bundled else { return "not in this build" }
        guard !tools.linked.isEmpty else { return "not installed" }
        return tools.missing.isEmpty
            ? tools.linked.joined(separator: ", ")
            : "\(tools.linked.joined(separator: ", ")) (missing \(tools.missing.joined(separator: ", ")))"
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func refresh() async {
        let found = await Task.detached(priority: .userInitiated) {
            TerminalToolingOperationExecution.status()
        }.value
        tools = found.tools
        completions = found.completions
        sourceLine = found.fallbackSourceLine
        loaded = true
    }

    private func run(_ action: TerminalAction) {
        Task {
            if action.reloadsStatus { running = action }
            let result = await perform(action)
            if action.reloadsStatus { await refresh() }
            running = nil
            show(result, for: action)
        }
    }

    private func perform(_ action: TerminalAction) async -> (succeeded: Bool, message: String) {
        switch action {
        case .installTools:
            let outcome = await Task.detached(priority: .userInitiated) {
                TerminalToolingOperationExecution.install()
            }.value
            let result = outcome.result
            if let message = result.message { return (false, message) }
            guard !result.linked.isEmpty else {
                return (true, "Already installed in \(abbreviate(result.directory)).")
            }
            return (
                true,
                "Linked \(result.linked.joined(separator: ", ")) in \(abbreviate(result.directory))."
            )
        case .removeTools:
            let outcome = await Task.detached(priority: .userInitiated) {
                TerminalToolingOperationExecution.remove()
            }.value
            let result = outcome.result
            if let message = result.message { return (false, message) }
            guard !result.linked.isEmpty else { return (true, "Nothing to remove.") }
            return (true, "Removed \(result.linked.joined(separator: ", ")).")
        case .installCompletions:
            let result = await Task.detached(priority: .userInitiated) {
                TerminalToolingOperationExecution.installCompletions()
            }.value
            if !result.failures.isEmpty {
                let failures = result.failures.map {
                    "\($0.shell.rawValue): \($0.message)"
                }.joined(separator: "; ")
                return (false, "Could not install every completion script: \(failures)")
            }
            let count =
                result.installed.count == 1
                ? "1 script" : "\(result.installed.count) scripts"
            return (
                true,
                "Wrote \(count) and the ~/.zshrc line. Run  exec zsh  in any open terminal."
            )
        case .copySourceLine:
            let line = await Task.detached(priority: .userInitiated) {
                TerminalToolingOperationExecution.fallbackSource(for: .zsh)
            }.value
            sourceLine = line
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            return (true, "Copied the line to the clipboard.")
        }
    }

    private func show(_ result: (succeeded: Bool, message: String), for action: TerminalAction) {
        outcomeStamp += 1
        let stamp = outcomeStamp
        outcome = ActionOutcome(
            action: action, succeeded: result.succeeded, message: result.message, stamp: stamp)
        Task {
            try? await Task.sleep(for: .seconds(result.succeeded ? 4 : 8))
            if outcome?.stamp == stamp { outcome = nil }
        }
    }
}

private enum TerminalAction: Equatable {
    case installTools
    case removeTools
    case installCompletions
    case copySourceLine

    var reloadsStatus: Bool { self != .copySourceLine }
}

private enum ActionPhase: Equatable {
    case idle
    case running
    case done
    case failed
}

private struct ActionOutcome: Equatable {
    var action: TerminalAction
    var succeeded: Bool
    var message: String
    var stamp: Int
}

private struct CheckingLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            ProgressView().controlSize(.mini)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct ActionButton: View {
    let idle: String
    let running: String
    let done: String
    let phase: ActionPhase
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(5)) {
                marker
                Text(title)
            }
        }
        .disabled(!enabled || phase == .running)
        .animation(.easeInOut(duration: 0.18), value: phase)
    }

    @ViewBuilder private var marker: some View {
        switch phase {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch phase {
        case .running: return running
        case .done: return done
        case .idle, .failed: return idle
        }
    }
}

private struct SectionFooter: View {
    let help: String
    let outcome: ActionOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(help)
            if let outcome {
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(5)) {
                    Image(
                        systemName: outcome.succeeded
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
                    Text(outcome.message)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .transition(.opacity)
            }
        }
        .font(.system(size: UIScale.pt(10)))
        .animation(.easeInOut(duration: 0.18), value: outcome)
    }
}
