import EdithKit
import SwiftUI

struct PluginsPage: View {
    @State private var previewSkill: EdithSkill?
    @State private var model = SkillsModel.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: UIScale.pt(20)) {
                PageHeader {
                    Text("Plugins")
                } accessory: {
                    Text("Skills built for Edith, ready for your agents.")
                        .font(.system(size: UIScale.pt(13)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    HStack {
                        Text("Edith skills")
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                        Spacer()
                        Text("\(model.agents.count) agents found on this Mac")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.skills) { skill in
                        SkillCatalogRow(
                            skill: skill, agents: model.agents,
                            installed: model.installedAgents[skill.id]?.isEmpty == false,
                            disabled: model.isInstalling,
                            preview: { previewSkill = skill },
                            install: { agent in model.present(skill, agentID: agent) })
                    }
                    Text(
                        "Install once for all your projects. Choose your agents at each install, with your preferences remembered."
                    )
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                }
                .pageGutter(compact)
            }
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
        }
        .background(DashSkin.paper(dark))
        .task {
            guard automaticActionsEnabled else { return }
            model.discoverAgents()
        }
        .sheet(item: $previewSkill) { skill in
            SkillPreviewSheet(skill: skill)
        }
        .sheet(item: $model.presentedSkill) { skill in
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

    var body: some View {
        HStack(spacing: UIScale.pt(16)) {
            Button(action: preview) {
                HStack(spacing: UIScale.pt(16)) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit()
                        .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        Text(skill.name)
                            .font(.system(size: UIScale.pt(17), weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
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
            HStack(spacing: 0) {
                Button {
                    install(nil)
                } label: {
                    Text(installed ? "Installed" : "Install")
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
        }
        .padding(UIScale.pt(22))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(
                DashSkin.line(scheme == .dark)))
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
