import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionSetupModel: CompanionRefreshable {
    private(set) var machines: [CompanionMachine] = []
    private(set) var plan: CompanionPlan?
    private(set) var busy = false
    private(set) var error: String?
    var name = ""
    var transport = "local"
    var at = ""

    static let transports = ["local", "ssh", "context"]
    static let tiers = ["gpu-large", "gpu-small", "apple-metal", "cpu-only"]

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func refresh() async {
        do {
            let client = client
            machines = try await client.machines()
            plan = try? await client.machinePlan()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func add() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.addMachine(name: trimmed, transport: transport, endpoint: at)
            name = ""
            at = ""
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func probe(_ machine: CompanionMachine) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.probeMachine(name: machine.name)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setProfile(_ machine: CompanionMachine, tier: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.setMachineProfile(name: machine.name, profile: tier)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CompanionSetupScreen: View {
    @Bindable var model: CompanionSetupModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if let error = model.error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.orange)
                }
                addCard
                machinesCard
                planCard
            }
            .pageContent(compact)
        }
        .task(id: generation) { if requestsEnabled { await model.refresh() } }
    }

    private var addCard: some View {
        SkinCard(title: "Add a machine", note: "the stack can run anywhere", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(spacing: UIScale.pt(8)) {
                    field("name", text: $model.name)
                    Picker("", selection: $model.transport) {
                        ForEach(CompanionSetupModel.transports, id: \.self) { transport in
                            Text(transport).tag(transport)
                        }
                    }
                    .labelsHidden()
                    .frame(width: UIScale.pt(110))
                    if model.transport != "local" {
                        field(
                            model.transport == "ssh" ? "user@host" : "context name",
                            text: $model.at)
                    }
                    CompanionAsyncButton("Add", filled: true, disabled: model.busy) {
                        await model.add()
                    }
                }
                Text(
                    "Nothing is assumed about it. Probing asks the machine what it is, and the "
                        + "tier that comes back can be overridden."
                )
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private var machinesCard: some View {
        SkinCard(title: "Machines", note: "what was detected", dark: dark) {
            if model.machines.isEmpty {
                Text("No machines yet. Adding this one is the whole of a single machine setup.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    ForEach(model.machines, id: \.id) { machine in
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                                Text(machine.name)
                                    .font(.system(size: UIScale.pt(13), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                MindChip(
                                    label: machine.effectiveProfile,
                                    tone: machine.effectiveProfile == "cpu-only"
                                        ? .orange : .green)
                                Spacer(minLength: 0)
                                CompanionAsyncButton("Probe", disabled: model.busy) {
                                    await model.probe(machine)
                                }
                            }
                            Text(machine.plainEnglish)
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            HStack(spacing: UIScale.pt(6)) {
                                ForEach(CompanionSetupModel.tiers, id: \.self) { tier in
                                    Button(tier) {
                                        Task { await model.setProfile(machine, tier: tier) }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: UIScale.pt(11)))
                                    .foregroundStyle(
                                        machine.effectiveProfile == tier
                                            ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                                    )
                                    .pointerCursor()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var planCard: some View {
        SkinCard(title: "Plan", note: "what would run where", dark: dark) {
            if let plan = model.plan, !plan.placements.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    ForEach(Array(plan.placements.enumerated()), id: \.offset) { _, placement in
                        HStack(spacing: UIScale.pt(8)) {
                            Text(placement.machine)
                                .font(.system(size: UIScale.pt(12), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(placement.role)
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(placement.service)
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                    }
                    if !plan.compose.isEmpty {
                        Text("compose files: \(plan.compose.joined(separator: ", "))")
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Add and probe a machine to see the placement it proposes.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(12.5)))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(6))
            .background(DashSkin.paper2(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
            .frame(minWidth: UIScale.pt(130))
    }

}
