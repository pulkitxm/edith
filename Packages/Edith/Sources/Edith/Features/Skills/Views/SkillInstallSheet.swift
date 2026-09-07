import EdithKit
import SwiftUI

struct SkillInstallSheet: View {
    @Bindable var model: SkillsModel
    let skill: EdithSkill
    @Environment(\.dismiss) private var dismiss

    private var targetCount: String {
        model.selectedAgentIDs.count == 1 ? "1 agent" : "\(model.selectedAgentIDs.count) agents"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HStack(alignment: .top, spacing: UIScale.pt(14)) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: UIScale.pt(48), height: UIScale.pt(48))
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    Text(model.installationSucceeded ? "Plugin installed" : "Install plugin")
                        .font(.system(size: UIScale.pt(21), weight: .semibold))
                    Text(skill.name).font(.system(size: UIScale.pt(14), weight: .medium))
                        .textSelection(.enabled)
                    Text("Edith · Remote development").font(
                        .system(size: UIScale.pt(12), design: .monospaced)
                    )
                    .foregroundStyle(.secondary)
                }
            }
            if model.installationSucceeded {
                Label(
                    "Available to \(targetCount) on this Mac.",
                    systemImage: "checkmark"
                )
                .font(.callout)
            } else {
                targets
                if !model.installerAvailable {
                    Label(
                        "Install Node.js 22.20 or later, then reopen this sheet to enable installation.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = model.installationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            }
            if !model.installationLog.isEmpty {
                DisclosureGroup("Installation output") {
                    ScrollView {
                        Text(model.installationLog)
                            .font(.system(size: UIScale.pt(10), design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: UIScale.pt(120))
                }
                .font(.caption)
            }
            Divider()
            HStack {
                if model.isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing for \(targetCount)…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.installationSucceeded ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isInstalling)
                if !model.installationSucceeded {
                    Button("Install for \(targetCount)") {
                        Task { await model.install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        model.isInstalling || model.selectedAgentIDs.isEmpty
                            || !model.installerAvailable)
                }
            }
        }
        .padding(UIScale.pt(28))
        .frame(width: UIScale.pt(600))
        .interactiveDismissDisabled(model.isInstalling)
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                Text("Agents on this Mac").font(.system(size: UIScale.pt(13), weight: .semibold))
                Spacer()
                Text("\(model.selectedAgentIDs.count) of \(model.agents.count) selected").font(
                    .caption
                ).foregroundStyle(.secondary)
            }
            if model.agents.isEmpty {
                Text(
                    "No supported agents found. Install and open an agent, then reopen this sheet."
                )
                .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.agents) { agent in
                            HStack(spacing: UIScale.pt(12)) {
                                SkillAgentLogo(agent: agent)
                                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                    Text(agent.name)
                                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                                    Text(
                                        agent.resolvedDirectory(
                                            home: FileManager.default.homeDirectoryForCurrentUser,
                                            environment: ProcessInfo.processInfo.environment
                                        ).path.replacingOccurrences(
                                            of: FileManager.default.homeDirectoryForCurrentUser
                                                .path,
                                            with: "~")
                                    )
                                    .font(.system(size: UIScale.pt(10), design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Toggle(
                                    agent.name,
                                    isOn: Binding(
                                        get: { model.selectedAgentIDs.contains(agent.id) },
                                        set: { model.setSelected(agent.id, enabled: $0) }
                                    )
                                )
                                .labelsHidden()
                                .accessibilityLabel(agent.name)
                                .toggleStyle(.switch).controlSize(.small).fixedSize()
                            }
                            .padding(.horizontal, UIScale.pt(12))
                            .padding(.vertical, UIScale.pt(10))
                            Divider()
                        }
                    }
                }
                .frame(height: UIScale.pt(CGFloat(min(model.agents.count, 5)) * 61))
                .disabled(model.isInstalling)
            }
            Text(
                model.singleAgentOverride
                    ? "This agent is selected for this install. Changing toggles saves a new selection."
                    : "Your selections are remembered for every plugin, including agents you turn off."
            )
            .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            Text(
                "Agents using the same skills folder share installed skills. Existing versions of this skill will be replaced."
            )
            .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
        }
    }
}
