import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageMachineSettingsRows: View {
    @Environment(\.usageUIClient) private var client
    @State private var machines: [Machine] = []
    @State private var selected: Set<UUID> = []
    @State private var summaries: [UUID: UsageMachineSummaryPayload] = [:]
    @State private var failure: String?
    @State private var status = ""
    @State private var operation: Task<Void, Never>?
    @State private var collectingLocally = false

    private var collecting: Bool {
        client?.refreshing
            ?? (collectingLocally || UsageWorkerOperations.controller?.refreshing == true)
    }

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
                    Text(statusText)
                        .settingsCaption()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if collecting {
                        SkeletonGroup {
                            SkeletonBlock(width: 16, height: 16, corner: 8)
                        }
                        Button("Stop") { stop() }
                    } else {
                        Button("Collect now") { collect() }
                            .disabled(selected.isEmpty)
                    }
                }
            }
            if let failure { Text(failure).settingsCaption().foregroundStyle(.red) }
        } header: {
            Text("Collected over SSH")
        } footer: {
            Text(
                "Edith runs its collector on a ticked machine over SSH and installs what it "
                    + "is missing there. Each agent it finds arrives as its own usage source."
            )
            .font(.system(size: UIScale.pt(10)))
        }
        .pageTask { await reload() }
        .onChange(of: collecting) { was, now in
            if was, !now {
                status = client?.failure ?? "collected"
                Task { await reload() }
            }
        }
        .onDisappear {
            operation?.cancel(); operation = nil
        }
    }

    private var statusText: String {
        if collecting, let line = client?.progressLine { return line }
        if !status.isEmpty { return status }
        let count = selected.count
        if count == 0 { return "No machines counted" }
        return count == 1 ? "1 machine counted" : "\(count) machines counted"
    }

    private func row(_ machine: Machine) -> some View {
        let on = selected.contains(machine.id)
        let summary = summaries[machine.id]
        return HStack(spacing: UIScale.pt(8)) {
            Toggle(isOn: Binding(get: { on }, set: { include(machine, $0) })) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(machine.name)
                    Text(detail(machine, summary)).settingsCaption()
                }
            }
            Spacer(minLength: 0)
            if summary != nil {
                Button {
                    forget(machine)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.edith(.borderless))
                .help("Drop what \(machine.name) gave and stop counting it")
                .accessibilityLabel("Forget history for \(machine.name)")
            }
        }
    }

    private func detail(_ machine: Machine, _ summary: UsageMachineSummaryPayload?) -> String {
        guard let summary else { return machine.subtitle }
        let when = Date(timeIntervalSince1970: summary.collectedAt)
            .formatted(date: .abbreviated, time: .shortened)
        return "\(DashFmt.usdFull(summary.cost)) · \(summary.days) days · \(when)"
    }

    private func reload() async {
        if let client {
            machines = (try? await client.value("usage.ui.machines", as: [Machine].self)) ?? []
            let found =
                (try? await client.value(
                    "usage.ui.machines.summaries", as: [UsageMachineSummaryPayload].self)) ?? []
            summaries = Dictionary(found.map { ($0.machineID, $0) }) { first, _ in first }
        } else {
            guard SurfaceHostContext.current?.activeIDs.contains("machines") == true else {
                return
            }
            machines = MachineRegistry.machines().filter { $0.id != Machine.localID }
            summaries = Dictionary(
                machines.compactMap { machine in
                    (try? UsageCLIMachines.summary(machine)).map {
                        (
                            machine.id,
                            UsageMachineSummaryPayload(
                                machineID: machine.id, cost: $0.cost, days: $0.days,
                                collectedAt: $0.collectedAt.timeIntervalSince1970)
                        )
                    }
                }
            ) { first, _ in first }
        }
        selected = Set(
            (SharedDefaults.store.stringArray(forKey: UsageMachinesPeer.selectedDefaultsKey)
                ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func collect() {
        status = "reaching the machines…"
        if let client {
            client.perform("usage.refresh", object: ["machinePolicy": "all"])
        } else {
            collectingLocally = true
            _ = try? UsageWorkerOperations.requestRefresh(machinePolicy: .all)
            collectingLocally = false
        }
    }

    private func stop() {
        if let client {
            client.perform("usage.refresh.cancel")
        } else {
            Task { await UsageWorkerOperations.controller?.cancelRefresh() }
        }
        status = "stopped"
    }

    private func forget(_ machine: Machine) {
        operation?.cancel()
        operation = Task {
            do {
                if let client {
                    _ = try await client.invoke(
                        "usage.machines.forget",
                        payload: JSONSerialization.data(withJSONObject: [
                            "machineID": machine.id.uuidString, "confirm": true,
                        ]))
                } else {
                    try await UsageWorkerOperations.forgetMachine(machine.id)
                }
                await reload()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func include(_ machine: Machine, _ included: Bool) {
        if included { selected.insert(machine.id) } else { selected.remove(machine.id) }
        if let client = client {
            client.perform(
                "usage.machines.select",
                object: ["machineID": machine.id.uuidString, "included": included])
        } else {
            SharedDefaults.store.set(
                selected.map(\.uuidString).sorted(), forKey: UsageMachinesPeer.selectedDefaultsKey)
        }
        if client == nil,
            let group = DashboardModel.shared.machineGroups.first(where: {
                $0.id.lowercased() == machine.id.uuidString.lowercased()
            })
        {
            DashboardModel.shared.showMachine(group, included)
        }
    }
}
