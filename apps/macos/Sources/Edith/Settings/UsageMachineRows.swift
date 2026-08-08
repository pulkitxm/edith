import EdithKit
import SwiftUI

struct UsageMachineRows: View {
    let extensionEnabled: Bool

    @State private var machines: [Machine] = []
    @State private var counted: Set<UUID> = []
    @State private var summaries: [UUID: MachineUsageSummary] = [:]
    @State private var asked = false

    var body: some View {
        Section {
            if machines.isEmpty {
                Text("No machines are configured yet. Add one under Machines.")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(machines) { machine in
                    row(machine)
                }
                HStack {
                    Text(footnote)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(asked ? "Collecting…" : "Collect now") { collect() }
                        .pointerCursor()
                        .disabled(counted.isEmpty || asked)
                }
            }
        } header: {
            Text("Collected over SSH")
        } footer: {
            Text(
                "Edith runs its collector on a ticked machine over SSH and installs what it "
                    + "is missing there. Each agent it finds arrives as its own usage source."
            )
            .font(.system(size: UIScale.pt(10)))
        }
        .disabled(!extensionEnabled)
        .opacity(extensionEnabled ? 1 : 0.5)
        .onAppear(perform: reload)
    }

    private var footnote: String {
        let n = counted.count
        if n == 0 { return "No machines counted" }
        return n == 1 ? "1 machine counted" : "\(n) machines counted"
    }

    private func row(_ machine: Machine) -> some View {
        let on = counted.contains(machine.id)
        let summary = summaries[machine.id]
        return HStack(spacing: UIScale.pt(8)) {
            Toggle(isOn: Binding(get: { on }, set: { _ in toggle(machine) })) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(machine.name)
                    Text(detail(machine, summary))
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                }
            }
            .pointerCursor()
            Spacer(minLength: 0)
            if summary != nil {
                Button {
                    forget(machine)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .pointerCursor()
                .help("Drop what \(machine.name) gave and stop counting it")
            }
        }
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
