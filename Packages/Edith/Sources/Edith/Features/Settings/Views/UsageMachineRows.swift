import EdithKit
import SwiftUI

struct UsageMachineRows: View {
    let extensionEnabled: Bool

    @State private var machines: [Machine] = []
    @State private var counted: Set<UUID> = []
    @State private var summaries: [UUID: MachineUsageSummary] = [:]
    @State private var collecting: Task<Void, Never>?
    @State private var reloadTask: Task<Void, Never>?
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
        .onDisappear { reloadTask?.cancel() }
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
        reloadTask?.cancel()
        reloadTask = Task {
            let found = await Task.detached(priority: .utility) {
                MachineUsageRows.summariesByMachineID(MachineUsageStore.summaries())
            }.value
            guard !Task.isCancelled else { return }
            summaries = found
            reloadTask = nil
        }
    }

    private func toggle(_ machine: Machine) {
        UsageCollectionOperationExecution.setMachineCounted(
            !counted.contains(machine.id), machineID: machine.id)
        reload()
    }

    private func forget(_ machine: Machine) {
        Task {
            _ = await Task.detached(priority: .utility) {
                UsageCollectionOperationExecution.forgetMachine(machineID: machine.id)
            }.value
            reload()
        }
    }

    private func collect() {
        guard collecting == nil else { return }
        let targets = MachineUsageSelection.included(in: machines)
        guard !targets.isEmpty else { return }
        let registry = machines
        status = "reaching \(targets.count == 1 ? targets[0].name : "the machines")…"
        collecting = Task {
            let result = await UsageCollectionOperationExecution.collectMachines(
                UsageMachineCollectionInput(
                    targets: targets, registry: registry, dataDirectory: Repo.dataDir,
                    timeout: MachineUsageCollector.defaultTimeout, verbose: false),
                includeSuccessfulMachines: false,
                onEvent: { event in
                    guard let line = MachineUsageRows.spoken(event) else { return }
                    Task { @MainActor in status = line }
                })
            let round = result.round
            await MainActor.run {
                reload()
                status = MachineUsageRows.outcome(round)
                collecting = nil
            }
        }
    }

    private func stop() {
        collecting?.cancel()
        collecting = nil
        status = "stopped"
    }
}

enum MachineUsageRows {
    static func summariesByMachineID(
        _ summaries: [MachineUsageSummary]
    ) -> [UUID: MachineUsageSummary] {
        summaries.reduce(into: [:]) { result, candidate in
            guard let existing = result[candidate.machineID] else {
                result[candidate.machineID] = candidate
                return
            }
            if prefers(candidate, over: existing) {
                result[candidate.machineID] = candidate
            }
        }
    }

    private static func prefers(
        _ candidate: MachineUsageSummary, over existing: MachineUsageSummary
    ) -> Bool {
        if candidate.collectedAt != existing.collectedAt {
            return candidate.collectedAt > existing.collectedAt
        }
        let candidateText = [
            candidate.name, candidate.slug, candidate.host,
            candidate.sources.joined(separator: "\u{0}"),
        ]
        let existingText = [
            existing.name, existing.slug, existing.host,
            existing.sources.joined(separator: "\u{0}"),
        ]
        if candidateText != existingText {
            return candidateText.lexicographicallyPrecedes(existingText)
        }
        if candidate.days != existing.days { return candidate.days > existing.days }
        if candidate.cost != existing.cost { return candidate.cost > existing.cost }
        return candidate.tokens > existing.tokens
    }

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
