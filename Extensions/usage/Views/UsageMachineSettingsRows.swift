import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageMachineSettingsRows: View {
    @State private var machines: [Machine] = []
    @State private var selected: Set<UUID> = []
    @State private var failure: String?
    @State private var forget: Machine?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Section("Remote usage") {
            if machines.isEmpty {
                Text("Install and enable Machines to collect usage from your registered machines.")
                    .settingsCaption()
            }
            ForEach(machines) { machine in
                HStack {
                    Toggle(
                        machine.name,
                        isOn: Binding(
                            get: { selected.contains(machine.id) }, set: { include(machine, $0) }))
                    Button("Forget history", role: .destructive) { forget = machine }
                }
            }
            if !machines.isEmpty {
                Button("Refresh selected machines") {
                    _ = try? UsageWorkerOperations.requestRefresh(machinePolicy: .all)
                }
            }
            if let failure { Text(failure).settingsCaption().foregroundStyle(.red) }
        }
        .pageTask {
            if let client = UsageUIClient.current {
                machines = (try? await client.value("usage.ui.machines", as: [Machine].self)) ?? []
            } else {
                guard SurfaceHostContext.current?.activeIDs.contains("machines") == true else {
                    return
                }
                machines = MachineRegistry.machines().filter { $0.id != Machine.localID }
            }
            selected = Set(
                (SharedDefaults.store.stringArray(forKey: UsageMachinesPeer.selectedDefaultsKey)
                    ?? []).compactMap(
                        UUID.init(uuidString:)))
        }
        .onDisappear {
            operation?.cancel(); operation = nil
        }
        .confirmationDialog(
            "Forget this machine’s cached usage history?",
            isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } })
        ) {
            if let machine = forget {
                Button("Forget " + machine.name, role: .destructive) {
                    operation?.cancel()
                    operation = Task {
                        do { try await UsageWorkerOperations.forgetMachine(machine.id) } catch {
                            if !Task.isCancelled { failure = error.localizedDescription }
                        }
                    }
                    forget = nil
                }
            }
            Button("Cancel", role: .cancel) { forget = nil }
        }
    }

    private func include(_ machine: Machine, _ included: Bool) {
        if included { selected.insert(machine.id) } else { selected.remove(machine.id) }
        if let client = UsageUIClient.current {
            client.perform(
                "usage.machines.select",
                object: ["machineID": machine.id.uuidString, "included": included])
        } else {
            SharedDefaults.store.set(
                selected.map(\.uuidString).sorted(), forKey: UsageMachinesPeer.selectedDefaultsKey)
        }
        if let group = DashboardModel.shared.machineGroups.first(where: {
            $0.id.lowercased() == machine.id.uuidString.lowercased()
        }) {
            DashboardModel.shared.showMachine(group, included)
        }
    }
}
