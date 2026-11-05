import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionDocuments
import SwiftUI

struct PluginsPage: View {
    @State private var previewSkill: EdithSkill?
    @Bindable var model: SkillsModel

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
        PageScaffold(width: .readable) {
            PageHeader(
                "Plugins",
                subtitle:
                    "Teach your coding agents to use Edith. A skill is a short instruction file: installing one adds a small folder to the agent, and you can remove it any time."
            )
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                PageSectionHeader("Edith skills") {
                    if model.agentsLoaded {
                        Text(agentSummary)
                            .font(.edithText(.callout))
                            .foregroundStyle(.secondary)
                    } else {
                        SkeletonGroup {
                            SkeletonBlock(width: 164, height: 11)
                        }
                        .frame(width: UIScale.pt(164), height: UIScale.pt(11))
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
                        unavailableReason: model.agentsLoaded
                            ? nil : "Looking for agents on this Mac",
                        preview: { previewSkill = skill },
                        install: { agent in
                            Task { await model.present(skill, agentID: agent) }
                        })
                }
                Text(
                    "Install once and every project on this Mac can use it. The arrow next to Install picks a single agent."
                )
                .font(.edithText(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    var unavailableReason: String?
    let preview: () -> Void
    let install: (String?) -> Void
    @Environment(\.compactLayout) private var compact

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    description
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .center, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    description
                    actions
                }
            }
        }
        .padding(UIScale.pt(PageMetrics.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
    }

    private var description: some View {
        HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            PageGuideBadge(symbolName: skill.symbol, size: 40)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(skill.name)
                    .font(.edithText(.headline))
                    .accessibilityAddTraits(.isHeader)
                Text(skill.summary)
                    .font(.edithText(.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(skill.detail)
                    .font(.edithText(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, UIScale.pt(2))
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            Button("Preview", action: preview)
                .buttonStyle(.edith(.secondary))
                .help("Read the skill instructions and copy the Markdown")
                .accessibilityLabel("Preview \(skill.name)")
            installActions
        }
        .fixedSize()
    }

    private var installActions: some View {
        HStack(spacing: UIScale.pt(2)) {
            Button {
                install(nil)
            } label: {
                if installed {
                    Label("Installed", systemImage: "checkmark")
                } else {
                    Text("Install")
                }
            }
            .buttonStyle(.edith(.secondary))
            .help(
                unavailableReason
                    ?? (installed
                        ? "Already installed. Click to reinstall or update."
                        : "Choose agents and install this skill"))
            Menu {
                if agents.isEmpty { Text("No agents found on this Mac") }
                ForEach(agents) { agent in
                    Button {
                        install(agent.id)
                    } label: {
                        Label {
                            Text("Install for \(agent.name)\u{2026}")
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
                    .font(.system(size: UIScale.pt(9), weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.edith(.secondary))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Install for one agent")
            .accessibilityLabel("Choose an agent for \(skill.name)")
        }
        .disabled(disabled)
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
                    .font(.edithText(.headline))
            }
        }
        .frame(width: UIScale.pt(24), height: UIScale.pt(24))
        .frame(width: UIScale.pt(40), height: UIScale.pt(40))
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .accessibilityHidden(true)
    }
}
