import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionDocuments
import SwiftUI

struct PluginsPage: View {
    @State private var previewSkill: EdithSkill?
    @Bindable var model: SkillsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    private var dark: Bool { scheme == .dark }

    private var presentedSkill: Binding<EdithSkill?> {
        Binding(
            get: { model.presentedSkill },
            set: { value in
                if value == nil {
                    Task { await model.dismissPresentation() }
                } else {
                    model.presentedSkill = value
                }
            })
    }

    private var agentSummary: String {
        switch model.agents.count {
        case 0: "No agents found on this Mac"
        case 1: "1 agent found on this Mac"
        default: "\(model.agents.count) agents found on this Mac"
        }
    }

    var body: some View {
        PageScaffold {
            PageHeader {
                Text("Plugins")
            } accessory: {
                Text("Teach your coding agents to use Edith. Pick a skill, then install it.")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                PageSectionHeader(
                    "Edith skills",
                    subtitle:
                        "A skill is a short instruction file that teaches your coding agent how to use Edith. Installing one only adds a small folder to the agent, and you can remove it any time."
                ) {
                    if model.agentsLoaded {
                        Text(agentSummary)
                            .font(.edithText(.caption))
                            .foregroundStyle(.secondary)
                    } else {
                        SkeletonGroup {
                            SkeletonBlock(width: 164, height: 11)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Discovering installed agents")
                    }
                }
                if model.agentsLoaded && model.agents.isEmpty {
                    PageNotice(
                        "Edith could not find a coding agent such as Claude Code, Cursor or Codex on this Mac. You can still preview any skill and copy its Markdown into your agent by hand.",
                        title: "No agents found", tone: .warning,
                        symbol: "person.crop.circle.badge.questionmark"
                    ) {
                        EmptyView()
                    } actions: {
                        Button("Check again") { Task { await model.discoverAgents() } }
                            .buttonStyle(.edith(.secondary))
                    }
                } else if model.agentsLoaded && !model.installerAvailable {
                    PageNotice(
                        "Installing needs Node.js 22.20 or later (the npx command), which was not found. Previewing and copying skills still works.",
                        title: "Installer unavailable", tone: .warning
                    ) {
                        EmptyView()
                    } actions: {
                        Button("Check again") { Task { await model.discoverAgents() } }
                            .buttonStyle(.edith(.secondary))
                    }
                }
                ForEach(model.skills) { skill in
                    SkillCatalogRow(
                        skill: skill, agents: model.agents,
                        installed: model.installedAgents[skill.id]?.isEmpty == false,
                        disabled: model.isInstalling || !model.agentsLoaded,
                        preview: { previewSkill = skill },
                        install: { agent in
                            Task { await model.present(skill, agentID: agent) }
                        })
                }
                Text(
                    "Install once and every project on this Mac can use it. Tap a card to read the skill first. The arrow next to Install picks a single agent."
                )
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
            }
        }
        .pageTask {
            await model.discoverAgents()
        }
        .edithSheet(item: $previewSkill) { skill in
            SkillPreviewSheet(skill: skill, documents: model.documents)
        }
        .edithSheet(item: presentedSkill, dismissible: !model.isInstalling) { skill in
            SkillInstallSheet(model: model, skill: skill)
        }
    }
}

private struct SkillCatalogRow: View {
    let skill: EdithSkill
    let agents: [SkillAgent]
    let installed: Bool
    let disabled: Bool
    let preview: () -> Void
    let install: (String?) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    previewContent
                    HStack {
                        Spacer(minLength: 0); installActions
                    }
                }
            } else {
                HStack(spacing: UIScale.pt(16)) {
                    previewContent
                    installActions
                }
            }
        }
        .padding(UIScale.pt(22))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(
                DashSkin.line(scheme == .dark)))
    }

    private var previewContent: some View {
        Button(action: preview) {
            HStack(spacing: UIScale.pt(16)) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: UIScale.pt(40), height: UIScale.pt(40))
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    Text(skill.name)
                        .font(.system(size: UIScale.pt(17), weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(skill.summary)
                        .font(.system(size: UIScale.pt(13)))
                        .foregroundStyle(.secondary)
                    Text(skill.detail)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: UIScale.pt(8))
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: UIScale.pt(16)))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel("Preview \(skill.name)")
        .help("Preview skill instructions and copy Markdown")
    }

    private var installActions: some View {
        HStack(spacing: 0) {
            Button {
                install(nil)
            } label: {
                Text(installed ? "Installed" : "Install")
                    .help(
                        installed
                            ? "Already installed. Tap to reinstall or update."
                            : "Choose agents and install this skill"
                    )
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .padding(.horizontal, UIScale.pt(14))
                    .frame(height: UIScale.pt(30))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            Divider().frame(height: UIScale.pt(18))
            Menu {
                if agents.isEmpty { Text("No agents found on this Mac") }
                ForEach(agents) { agent in
                    Button {
                        install(agent.id)
                    } label: {
                        Label {
                            Text("Install for \(agent.name)…")
                        } icon: {
                            if let image = SkillBrand.menuImage(for: agent.id) {
                                Image(nsImage: image)
                                    .renderingMode(image.isTemplate ? .template : .original)
                            } else {
                                Image(systemName: "terminal")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .frame(width: UIScale.pt(28), height: UIScale.pt(30))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Choose an agent for \(skill.name)")
        }
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(6)).strokeBorder(.primary.opacity(0.12))
        )
        .disabled(disabled)
        .fixedSize()
    }
}

struct SkillAgentLogo: View {
    let agent: SkillAgent

    var body: some View {
        Group {
            if let image = SkillBrand.image(for: agent.id) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(String(agent.name.prefix(1)))
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
            }
        }
        .frame(width: UIScale.pt(25), height: UIScale.pt(25))
        .frame(width: UIScale.pt(40), height: UIScale.pt(40))
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .accessibilityHidden(true)
    }
}
