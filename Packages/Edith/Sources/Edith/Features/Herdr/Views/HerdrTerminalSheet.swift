import EdithKit
import SwiftUI

struct HerdrTerminalSheet: View {
    var store: HerdrStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var machineID = HerdrHostSnapshot.localID
    @State private var session = "default"
    @State private var workspace = ""
    @State private var directory = ""
    @State private var label = ""

    private var dark: Bool { scheme == .dark }

    private var machines: [(id: String, name: String)] {
        store.hosts.map { ($0.id, $0.name) }
    }

    private var sessions: [String] {
        let live = Set(
            store.agents.filter { $0.machineID == machineID }.map(\.session)
        ).sorted()
        return live.isEmpty ? ["default"] : live
    }

    private var workspaces: [(id: String, name: String)] {
        store.workspaceChoices(for: machineID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: "terminal")
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(DashSkin.gold)
                Text("New Terminal")
                    .font(DashSkin.serif(18))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            field("Machine") {
                Picker("", selection: $machineID) {
                    ForEach(machines, id: \.id) { machine in
                        Text(machine.name).tag(machine.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            HStack(spacing: UIScale.pt(10)) {
                field("Session") {
                    Picker("", selection: $session) {
                        ForEach(sessions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                field("Workspace") {
                    Picker("", selection: $workspace) {
                        Text("Current").tag("")
                        ForEach(workspaces, id: \.id) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            field("Directory") {
                TextField("Leave empty for the herdr default", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .font(DashSkin.mono(11.5))
            }
            field("Label") {
                TextField("Optional name for the tab", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            Text(
                "Creates a tab in the herdr session on that machine. The shell keeps running there when Edith is closed."
            )
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
            if let error = store.createError {
                Text(error)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: UIScale.pt(8)) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(HoverButtonStyle())
                Button("Create and open") {
                    Task { await create() }
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(store.creating)
            }
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(460))
        .background(DashSkin.paper(dark))
        .onAppear { session = sessions.first ?? "default" }
    }

    private func field<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func create() async {
        let machine: Machine? =
            machineID == HerdrHostSnapshot.localID
            ? nil
            : MachineRegistry.machines().first { $0.id.uuidString == machineID }
        let request = HerdrTerminalRequest(
            session: session, workspace: workspace.isEmpty ? nil : workspace,
            cwd: directory.isEmpty ? nil : directory,
            label: label.isEmpty ? nil : label)
        if await store.createTerminal(on: machine, request: request) != nil {
            dismiss()
        }
    }
}
