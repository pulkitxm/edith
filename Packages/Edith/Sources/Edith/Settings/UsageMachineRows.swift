import EdithKit
import SwiftUI

struct UsageMachineRows: View {
    let extensionEnabled: Bool

    @State private var machines: [Machine] = []
    @State private var counted: Set<UUID> = []
    @State private var summaries: [UUID: MachineUsageSummary] = [:]
    @State private var collecting: Task<Void, Never>?
    @State private var status = ""

    var body: some View {
        Section {
            if machines.isEmpty {
                Text("No machines are configured yet. Add one under Machines.")
                    .settingsCaption()
            } else {
                ForEach(machines) { machine in
                    row(machine)
                }
                HStack(spacing: UIScale.pt(8)) {
                    Text(status.isEmpty ? footnote : status)
                        .settingsCaption()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if collecting != nil {
                        ProgressView().controlSize(.small)
                        Button("Stop") { stop() }.pointerCursor()
                    } else {
                        Button("Collect now") { collect() }
                            .pointerCursor()
                            .disabled(counted.isEmpty)
                    }
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
                        .settingsCaption()
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
        guard collecting == nil else { return }
        let targets = MachineUsageSelection.included(in: machines)
        guard !targets.isEmpty else { return }
        status = "reaching \(targets.count == 1 ? targets[0].name : "the machines")…"
        collecting = Task {
            let round = await MachineUsageRound.collect(targets) { event in
                guard let line = MachineUsageRows.spoken(event) else { return }
                Task { @MainActor in status = line }
            }
            await MainActor.run {
                reload()
                status = MachineUsageRows.outcome(round)
                collecting = nil
            }
            guard round.changedAnything else { return }
            IPC.post(IPC.Name.requestUsageRefresh)
        }
    }

    private func stop() {
        collecting?.cancel()
        collecting = nil
        status = "stopped"
    }
}

enum MachineUsageRows {
    static func spoken(_ event: UsageRefreshEvent) -> String? {
        switch event {
        case let .phase(name, detail, _): return "\(name): \(detail)"
        case let .note(text): return text
        default: return nil
        }
    }

    static func outcome(_ round: MachineUsageRoundResult) -> String {
        if round.skippedBecauseBusy { return "another collection is already running" }
        if let failure = round.failures.first, round.collected.isEmpty {
            return "\(failure.machine): \(failure.reason)"
        }
        let collected = round.collected.count
        let counted = collected == 1 ? "1 machine" : "\(collected) machines"
        guard round.failures.isEmpty else {
            return "\(counted) collected, \(round.failures.count) failed"
        }
        return collected == 0 ? "nothing to collect" : "\(counted) collected"
    }
}
