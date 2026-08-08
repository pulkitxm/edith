import EdithKit
import SwiftUI

struct UsageMachinesPicker: View {
    let dark: Bool
    let dismiss: () -> Void

    @State private var machines: [Machine] = []
    @State private var counted: Set<UUID> = []
    @State private var summaries: [UUID: MachineUsageSummary] = [:]
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text("Count agent usage from these machines too")
                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(6))
            Text(
                "Edith runs its collector on the machine over SSH and installs what it "
                    + "is missing there. Each agent arrives as its own source."
            )
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, UIScale.pt(6))
            Divider().opacity(0.4)
            if machines.isEmpty {
                Text("No machines are configured yet.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(UIScale.pt(8))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        ForEach(machines) { machine in
                            row(machine)
                        }
                    }
                }
                .frame(maxHeight: UIScale.pt(240))
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
        return n == 0 ? "No machines counted" : (n == 1 ? "1 machine counted" : "\(n) machines")
    }

    private func row(_ machine: Machine) -> some View {
        let on = counted.contains(machine.id)
        let summary = summaries[machine.id]
        return HStack(spacing: UIScale.pt(6)) {
            Button {
                toggle(machine)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(on ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
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
                }
                .buttonStyle(.plain).pointerCursor()
                .help("Drop what \(machine.name) gave and stop counting it")
            }
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(4))
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
