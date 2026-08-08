import EdithKit
import SwiftUI

struct UsageMachinesPicker: View {
    @ObservedObject var model: DashboardModel
    let dark: Bool
    let dismiss: () -> Void

    @State private var machines: [Machine] = []
    @State private var counted: Set<UUID> = []
    @State private var summaries: [UUID: MachineUsageSummary] = [:]
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("Machines")
                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(6))
            Text("Tick a machine to count it in the charts. Option-click to show it alone.")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UIScale.pt(6))
            if !model.machineGroups.isEmpty {
                Divider().opacity(0.4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        ForEach(model.machineGroups) { group in
                            shownRow(group)
                        }
                    }
                }
                .frame(maxHeight: UIScale.pt(420))
            }
            Divider().opacity(0.4)
            Text("COLLECTED OVER SSH")
                .font(DashSkin.mono(9.5)).tracking(UIScale.pt(1.2))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .padding(.horizontal, UIScale.pt(6))
            if machines.isEmpty {
                Text("No machines are configured yet.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(UIScale.pt(8))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        ForEach(machines) { machine in
                            collectRow(machine)
                        }
                    }
                }
                .frame(maxHeight: UIScale.pt(360))
            }
            Divider().opacity(0.4)
            HStack(spacing: UIScale.pt(10)) {
                Text(footnote)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
                Button(asked ? "Collecting…" : "Collect now") { collect() }
                    .buttonStyle(.plain).pointerCursor()
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.accent(dark))
                    .disabled(counted.isEmpty || asked)
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).pointerCursor()
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            .padding(.horizontal, UIScale.pt(6))
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(400))
        .onAppear(perform: reload)
    }

    private var footnote: String {
        guard !machines.isEmpty else { return "Add a machine under Machines" }
        let n = counted.count
        if n == 0 { return "No machines collected" }
        return n == 1 ? "1 machine collected" : "\(n) collected"
    }

    private func shownRow(_ group: MachineGroup) -> some View {
        let shown = model.machineIsShown(group)
        let partial = model.machineIsPartlyShown(group)
        let mark = shown ? "checkmark.circle.fill" : (partial ? "circle.lefthalf.filled" : "circle")
        return Button {
            if NSEvent.modifierFlags.contains(.option) {
                model.showOnlyMachine(group)
            } else {
                model.showMachine(group, !shown)
            }
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: mark)
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(
                        shown || partial ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(group.name)
                        .font(
                            .system(size: UIScale.pt(11.5), weight: shown ? .semibold : .regular)
                        )
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(group.agentSummary)
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: UIScale.pt(8))
                Text(agentCount(group))
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(9))
            .padding(.vertical, UIScale.pt(7))
            .contentShape(Rectangle())
        }
        .buttonStyle(MachineRowStyle(dark: dark))
        .pointerCursor()
        .padding(.horizontal, UIScale.pt(2))
    }

    private func agentCount(_ group: MachineGroup) -> String {
        group.sourceIDs.count == 1 ? "1 agent" : "\(group.sourceIDs.count) agents"
    }

    private func collectRow(_ machine: Machine) -> some View {
        let on = counted.contains(machine.id)
        let summary = summaries[machine.id]
        return HStack(spacing: UIScale.pt(2)) {
            Button {
                toggle(machine)
            } label: {
                HStack(spacing: UIScale.pt(8)) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(on ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(machine.name)
                            .font(
                                .system(
                                    size: UIScale.pt(11.5), weight: on ? .semibold : .regular)
                            )
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(detail(machine, summary))
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, UIScale.pt(9))
                .padding(.vertical, UIScale.pt(7))
                .contentShape(Rectangle())
            }
            .buttonStyle(MachineRowStyle(dark: dark))
            .pointerCursor()
            if summary != nil {
                Button {
                    forget(machine)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                        .contentShape(Rectangle())
                }
                .buttonStyle(MachineRowStyle(dark: dark))
                .pointerCursor()
                .help("Drop what \(machine.name) gave and stop counting it")
            }
        }
        .padding(.horizontal, UIScale.pt(2))
        .padding(.vertical, UIScale.pt(1))
    }

    private func detail(_ machine: Machine, _ summary: MachineUsageSummary?) -> String {
        guard let summary else { return machine.subtitle }
        let when = summary.collectedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(DashFmt.usdFull(summary.cost)) · \(summary.days) days · \(when)"
    }

    private func reload() {
        machines = MachineRegistry.machines()
        counted = MachineUsageSelection.machineIDs()
        var found: [UUID: MachineUsageSummary] = [:]
        for summary in MachineUsageStore.summaries() { found[summary.machineID] = summary }
        summaries = found
    }

    private func toggle(_ machine: Machine) {
        if counted.contains(machine.id) {
            MachineUsageSelection.exclude(machine.id)
        } else {
            MachineUsageSelection.include(machine.id)
        }
        reload()
    }

    private func forget(_ machine: Machine) {
        let dropped = MachineUsageStore.forget(machineID: machine.id)
        MachineUsageSelection.exclude(machine.id)
        if dropped { IPC.post(IPC.Name.requestUsageRefresh) }
        reload()
    }

    private func collect() {
        asked = true
        IPC.post(IPC.Name.requestUsageMachineCollect)
    }
}

private struct MachineRowStyle: ButtonStyle {
    let dark: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovering ? DashSkin.inkFaint(dark).opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .onHover { hovering = $0 }
    }
}
