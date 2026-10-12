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

    var body: some View {
        Form {
            Section {
                LabeledContent("Tools", value: model.toolSummary)
                LabeledContent("Location") {
                    Text(model.status?.tools.directory ?? "Checking...")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    action(
                        .installTools,
                        title: model.status?.tools.missing.isEmpty == true
                            ? "Reinstall" : "Install",
                        running: "Installing...",
                        enabled: model.status?.tools.bundled == true)
                    action(
                        .removeTools, title: "Remove", running: "Removing...",
                        enabled: model.status?.tools.linked.isEmpty == false)
                }
            } header: {
                Text("Command line tools")
            } footer: {
                Text(model.toolsHelp).settingsCaption()
                result(for: [.installTools, .removeTools])
            }
            Section {
                if let status = model.status {
                    ForEach(status.completions) { completion in
                        LabeledContent(completion.shell) {
                            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                                Label(
                                    completion.state.capitalized,
                                    systemImage: completion.state == "current"
                                        ? "checkmark.circle.fill" : "exclamationmark.circle"
                                )
                                .foregroundStyle(
                                    completion.state == "current" ? .green : .secondary)
                                Text(completion.path).font(.edithText(.caption))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                        }
                    }
                } else {
                    Text("Looking for completion scripts...").foregroundStyle(.secondary)
                }
                action(
                    .installCompletions, title: "Install completions",
                    running: "Writing scripts...",
                    enabled: model.status != nil)
            } header: {
                Text("Shell completion")
            } footer: {
                Text(
                    "A shell reads its completions once, when it starts. Run exec zsh in a terminal you already have open, or open a new tab."
                ).settingsCaption()
                result(for: [.installCompletions])
            }
            Section {
                Text(model.status?.fallbackSource ?? "Working out the path...")
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .textSelection(.enabled)
                action(
                    .copySourceLine, title: "Copy", running: "Copying...",
                    enabled: model.status?.fallbackSource.isEmpty == false)
            } header: {
                Text("If a shell still does not complete")
            } footer: {
                Text(
                    "Adding this to ~/.zshrc loads the completion directly instead of waiting for compinit to find it."
                ).settingsCaption()
                result(for: [.copySourceLine])
            }
            Section {
                Toggle("Keep completions up to date", isOn: $model.autoRefresh)
                Text(
                    "Rewrites completion scripts when Edith starts. Only touches files Edith wrote."
                ).settingsCaption()
            } header: {
                Text("On launch")
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { Task { await model.refresh() } }.disabled(model.refreshing)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Terminal")
        .pageTask(cancel: model.cancel) { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if automaticActions { Task { await model.refresh() } }
        }
    }

    private func action(
        _ action: HostToolingSettingsModel.Action, title: String, running: String,
        enabled: Bool
    ) -> some View {
        Button {
            model.run(action)
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                if model.running == action { ProgressView().controlSize(.mini) }
                Text(model.running == action ? running : title)
            }
        }.disabled(!enabled || model.running != nil)
    }

    @ViewBuilder private func result(for actions: [HostToolingSettingsModel.Action]) -> some View {
        if let outcome = model.outcome, actions.contains(outcome.action) {
            Text(outcome.message).settingsCaption()
                .foregroundStyle(outcome.succeeded ? .green : .red)
        }
    }
}
