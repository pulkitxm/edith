import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostToolingSettingsPage: View {
    @State private var model: HostToolingSettingsModel
    @Environment(\.automaticViewActionsEnabled) private var automaticActions

    init(model: HostToolingSettingsModel) { _model = State(initialValue: model) }

    init(defaults: UserDefaults) {
        let executable =
            HostToolingCLI.bundledLauncher()
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ed-launcher")
        let tooling = HostToolingCLI(
            home: FileManager.default.homeDirectoryForCurrentUser, executable: executable,
            path: (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(
                String.init))
        self.init(
            model: HostToolingSettingsModel(
                defaults: defaults, tooling: tooling,
                copy: { line in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                }))
    }

    private var loaded: Bool { model.status != nil }

    var body: some View {
        Form {
            toolsSection
            completionSection
            fallbackSection
            launchSection
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { Task { await model.refresh() } }.disabled(model.refreshing)
                }
            }
        }
        .edithForm()
        .navigationTitle("Terminal")
        .pageTask(cancel: model.cancel) { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if automaticActions { Task { await model.refresh() } }
        }
    }

    private var toolsSection: some View {
        Section {
            LabeledContent("Tools") {
                if loaded {
                    Text(model.toolSummary).foregroundStyle(.secondary)
                } else {
                    HostToolingCheckingLabel("Checking...")
                }
            }
            LabeledContent("Location") {
                if let tools = model.status?.tools {
                    Text(tools.directory.isEmpty ? "-" : Self.abbreviate(tools.directory))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    HostToolingCheckingLabel("Checking...")
                }
            }
            HStack(spacing: UIScale.pt(10)) {
                let complete = model.status?.tools.missing.isEmpty == true
                HostToolingActionButton(
                    idle: complete ? "Reinstall" : "Install",
                    running: complete ? "Reinstalling..." : "Installing...", done: "Installed",
                    phase: model.phase(of: .installTools),
                    enabled: model.running == nil && model.status?.tools.bundled == true
                ) { model.run(.installTools) }
                HostToolingActionButton(
                    idle: "Remove", running: "Removing...", done: "Removed",
                    phase: model.phase(of: .removeTools),
                    enabled: model.running == nil && model.status?.tools.linked.isEmpty == false
                ) { model.run(.removeTools) }
            }
        } header: {
            Text("Command line tools")
        } footer: {
            HostToolingSectionFooter(
                help: model.toolsHelp,
                outcome: model.outcome(for: [.installTools, .removeTools]))
        }
    }

    private var completionSection: some View {
        Section {
            if let status = model.status {
                if status.completions.isEmpty {
                    Text("No shells found.").foregroundStyle(.secondary)
                } else {
                    ForEach(status.completions) { completion in
                        LabeledContent(completion.shell) {
                            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                                HStack(spacing: UIScale.pt(6)) {
                                    Circle()
                                        .fill(Self.color(for: completion.state))
                                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                                    Text(Self.label(for: completion.state))
                                        .foregroundStyle(.secondary)
                                }
                                Text(Self.abbreviate(completion.path))
                                    .font(.system(size: UIScale.pt(10)))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                HostToolingCheckingLabel("Looking for shells...")
            }
            HostToolingActionButton(
                idle: "Install completions", running: "Writing scripts...", done: "Installed",
                phase: model.phase(of: .installCompletions),
                enabled: model.running == nil && loaded
            ) { model.run(.installCompletions) }
        } header: {
            Text("Shell completion")
        } footer: {
            HostToolingSectionFooter(
                help:
                    "A shell reads its completions once, when it starts. Run  exec zsh  in a terminal you already have open, or open a new tab.",
                outcome: model.outcome(for: [.installCompletions]))
        }
    }

    private var fallbackSection: some View {
        Section {
            if let source = model.status?.fallbackSource {
                Text(source)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .textSelection(.enabled)
            } else {
                HostToolingCheckingLabel("Working out the path...")
            }
            HostToolingActionButton(
                idle: "Copy", running: "Copy", done: "Copied",
                phase: model.phase(of: .copySourceLine),
                enabled: model.status?.fallbackSource.isEmpty == false
            ) { model.run(.copySourceLine) }
        } header: {
            Text("If a shell still does not complete")
        } footer: {
            HostToolingSectionFooter(
                help:
                    "Adding this to ~/.zshrc loads the completion directly, the way the ac CLI does, instead of waiting for compinit to find it.",
                outcome: model.outcome(for: [.copySourceLine]))
        }
    }

    private var launchSection: some View {
        Section {
            Toggle(isOn: $model.autoRefresh) {
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

    private static func label(for state: String) -> String {
        switch state {
        case "current": "up to date"
        case "stale": "out of date"
        default: "not installed"
        }
    }

    private static func color(for state: String) -> Color {
        switch state {
        case "current": .green
        case "stale": .orange
        default: .secondary
        }
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum HostToolingActionPhase: Equatable {
    case idle
    case running
    case done
    case failed
}

private struct HostToolingCheckingLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        SkeletonGroup {
            SkeletonBlock(width: 96, height: 9, corner: 4)
        }
        .accessibilityLabel(text)
    }
}

private struct HostToolingActionButton: View {
    let idle: String
    let running: String
    let done: String
    let phase: HostToolingActionPhase
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
            SkeletonGroup {
                SkeletonBlock(width: 12, height: 12, corner: 6)
            }
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
        case .running: running
        case .done: done
        case .idle, .failed: idle
        }
    }
}

private struct HostToolingSectionFooter: View {
    let help: String
    let outcome: HostToolingSettingsModel.Outcome?

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
