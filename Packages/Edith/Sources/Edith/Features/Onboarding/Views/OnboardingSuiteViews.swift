import AppKit
import EdithKit
import SwiftUI

struct SuiteChoiceCard: View {
    let pick: OnboardingSuitePick
    let selectedIDs: Set<String>
    let dark: Bool
    let toggleSuite: () -> Void
    let toggleAbility: (String) -> Void

    private var selectedCount: Int {
        pick.abilities.filter { selectedIDs.contains($0.id) }.count
    }

    private var selected: Bool { selectedCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Button(action: toggleSuite) {
                HStack(spacing: UIScale.pt(9)) {
                    Image(systemName: pick.suite.symbolName)
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        .foregroundStyle(
                            selected ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                        )
                        .frame(width: UIScale.pt(18))
                    Text(pick.suite.title)
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer(minLength: 0)
                    Image(
                        systemName: selectedCount == pick.abilities.count
                            ? "checkmark.circle.fill"
                            : (selected ? "circle.lefthalf.filled" : "circle")
                    )
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(selected ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                }
            }
            .buttonStyle(.edith(.borderless))
            Text(pick.suite.subtitle)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            AbilityChipRow(
                abilities: pick.abilities, selectedIDs: selectedIDs, dark: dark,
                toggle: toggleAbility)
            if pick.suite.requiresFleet {
                Text("requires Fleet, which is always on")
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(UIScale.pt(12))
        .background(
            selected ? DashSkin.accent(dark).opacity(0.08) : DashSkin.paper2(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .strokeBorder(
                    selected ? DashSkin.accent(dark).opacity(0.45) : DashSkin.line(dark)))
    }
}

private struct AbilityChipRow: View {
    let abilities: [ExtensionRegistryEntry]
    let selectedIDs: Set<String>
    let dark: Bool
    let toggle: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 5, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(5)) {
            ForEach(abilities) { ability in
                let on = selectedIDs.contains(ability.id)
                Button {
                    toggle(ability.id)
                } label: {
                    Text(ability.title)
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, UIScale.pt(6))
                        .padding(.vertical, UIScale.pt(3))
                        .frame(maxWidth: .infinity)
                        .background(
                            on
                                ? DashSkin.accent(dark).opacity(0.18)
                                : DashSkin.inkFaint(dark).opacity(0.1),
                            in: Capsule()
                        )
                        .foregroundStyle(on ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                }
                .buttonStyle(.edith(.borderless))
                .help(ability.subtitle)
            }
        }
    }
}

struct OnboardingAgentPanel: View {
    let dark: Bool
    @State private var registration = AgentRegistrationState.current
    @State private var jobs: [AgentJobSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                Circle()
                    .fill(registration == .enabled ? DashSkin.sage : Color.orange)
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                Text("edithd")
                    .font(DashSkin.mono(11, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(registration.title)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                Spacer(minLength: 0)
                if registration.needsAttention {
                    Button("Open Login Items") { AgentRegistrar.openLoginItemsSettings() }
                        .buttonStyle(.edith(.toolbar))
                }
            }
            if registration == .awaitingApproval {
                Text(
                    "macOS is waiting for you to allow Edith's background agent in Login Items "
                        + "and Extensions. Everything else here works meanwhile."
                )
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(displayedJobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 { Divider().opacity(0.4) }
                        HStack(spacing: UIScale.pt(8)) {
                            Text(job.descriptor.title)
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(DashSkin.ink(dark))
                            Spacer(minLength: 0)
                            Text(job.descriptor.trigger.title)
                                .font(DashSkin.mono(9.5))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(AgentDuration.cadence(job.descriptor.cadence))
                                .font(DashSkin.mono(9.5))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                                .frame(width: UIScale.pt(110), alignment: .trailing)
                        }
                        .padding(.horizontal, UIScale.pt(11))
                        .padding(.vertical, UIScale.pt(7))
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: UIScale.pt(210))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(DashSkin.line(dark)))
        }
        .onAppear(perform: refresh)
    }

    private var displayedJobs: [AgentJobSnapshot] {
        jobs.isEmpty ? AgentJobPreview.placeholders : jobs
    }

    private func refresh() {
        registration = .current
        jobs = (try? AgentClient.shared.jobSnapshots()) ?? []
    }
}

enum AgentJobPreview {
    static let placeholders: [AgentJobSnapshot] = AgentJobPlan.descriptors.map {
        AgentJobSnapshot(
            descriptor: $0, phase: .idle, subscribers: 0, lastRun: nil, lastDuration: nil,
            lastError: nil, runCount: 0)
    }
}

struct OnboardingConnectPanel: View {
    let dark: Bool
    @State private var status = CLIInstallStatus.unknown
    @State private var mcpRegistered = false

    private let example = "ed usage limits --json"

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            row(
                title: "The ed command",
                detail: status.detail,
                actionTitle: status.actionTitle,
                action: installCLI)
            row(
                title: "Claude Code and Codex",
                detail: mcpRegistered
                    ? "Registered. Your agents can call Edith's tools."
                    : "Adds Edith's MCP server so an agent can read usage, machines and more.",
                actionTitle: mcpRegistered ? nil : "Register",
                action: registerMCP)
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Text("Try it")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                HStack(spacing: UIScale.pt(8)) {
                    Text(example)
                        .font(DashSkin.mono(11))
                        .foregroundStyle(DashSkin.ink(dark))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(example, forType: .string)
                    }
                    .buttonStyle(.edith(.toolbar))
                }
                .padding(UIScale.pt(10))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(9))
                        .strokeBorder(DashSkin.line(dark)))
            }
        }
        .onAppear {
            status = CLIInstallStatus.current()
            mcpRegistered = MCPRegistration.isRegistered()
        }
    }

    private func row(
        title: String, detail: String, actionTitle: String?, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(detail)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.edith(.toolbar))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DashSkin.sage)
            }
        }
    }

    private func installCLI() {
        CLIInstaller.installIfNeeded()
        status = CLIInstallStatus.current()
    }

    private func registerMCP() {
        mcpRegistered = MCPRegistration.register()
    }
}
