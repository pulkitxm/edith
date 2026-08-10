import EdithKit
import SwiftUI

private struct PowerIconButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let enabled: Bool
    let dark: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(hovering && enabled ? tint : DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(24), height: UIScale.pt(20))
                .background(
                    tint.opacity(hovering && enabled ? 0.16 : 0),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .pointerCursor()
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

struct MachinePowerControls: View {
    @ObservedObject var session: MachineSession
    @ObservedObject var model: MachinesModel
    let dark: Bool

    @State private var confirmPower: String?
    @State private var message: String?
    @State private var messageIsFailure = false
    @State private var messageToken = 0

    private var wakeAddress: String? {
        session.machine.wakeMACAddress ?? session.facts.macAddress
    }

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            if let message {
                toast(message)
            }
            controls
        }
        .confirmationDialog(
            confirmPower == "reboot" ? "Restart this machine?" : "Shut this machine down?",
            isPresented: Binding(
                get: { confirmPower != nil }, set: { if !$0 { confirmPower = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirmPower == "reboot" ? "Restart" : "Shut down", role: .destructive) {
                runPower(confirmPower ?? "")
                confirmPower = nil
            }
            Button("Cancel", role: .cancel) { confirmPower = nil }
        } message: {
            Text("The SSH connection drops immediately. Edith reconnects when it comes back.")
        }
        .onChange(of: session.facts.macAddress) { _, mac in
            guard let mac, session.machine.wakeMACAddress == nil else { return }
            var updated = session.machine
            updated.wakeMACAddress = mac
            model.store.update(updated)
        }
    }

    private var controls: some View {
        HStack(spacing: UIScale.pt(1)) {
            PowerIconButton(
                symbol: "arrow.triangle.2.circlepath", tint: DashSkin.accent(dark),
                help: "Restart this machine", enabled: session.state.isConnected, dark: dark
            ) {
                confirmPower = "reboot"
            }
            PowerIconButton(
                symbol: "power", tint: DashSkin.danger, help: "Shut this machine down",
                enabled: session.state.isConnected, dark: dark
            ) {
                confirmPower = "poweroff"
            }
            PowerIconButton(
                symbol: "bolt", tint: DashSkin.gold,
                help: wakeAddress.map { "Wake this machine (\($0))" }
                    ?? "No wake address known yet",
                enabled: wakeAddress != nil, dark: dark
            ) {
                announce(model.wake(machine: session.machine), failure: false)
            }
        }
        .padding(UIScale.pt(2))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(9))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(0.5)))
    }

    private func toast(_ text: String) -> some View {
        let tone = messageIsFailure ? DashSkin.danger : DashSkin.sage
        return HStack(spacing: UIScale.pt(6)) {
            Image(systemName: messageIsFailure ? "exclamationmark.triangle" : "checkmark")
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            Text(text)
                .font(.system(size: UIScale.pt(11)))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, UIScale.pt(9))
        .padding(.vertical, UIScale.pt(4))
        .frame(maxWidth: UIScale.pt(260), alignment: .leading)
        .background(tone.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.opacity(0.3), lineWidth: UIScale.pt(0.5)))
        .help(text)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func announce(_ text: String?, failure: Bool) {
        guard let text, !text.isEmpty else { return }
        messageToken += 1
        let token = messageToken
        messageIsFailure = failure
        withAnimation(.easeOut(duration: 0.16)) { message = text }
        Task {
            try? await Task.sleep(for: .seconds(failure ? 8 : 4))
            guard token == messageToken else { return }
            withAnimation(.easeIn(duration: 0.16)) { message = nil }
        }
    }

    private func runPower(_ action: String) {
        Task {
            let stdin = SudoPassword.stdin(machineID: session.machine.id)
            let command =
                action == "reboot"
                ? ServiceCommands.reboot(withSudoPassword: stdin != nil)
                : ServiceCommands.shutdown(withSudoPassword: stdin != nil)
            let underway = action == "reboot" ? "Restarting…" : "Shutting down…"
            switch await session.runCommand(command, stdin: stdin, timeout: 20) {
            case .success:
                announce(underway, failure: false)
                session.stop()
            case let .failure(error):
                guard PowerOutcome.hostWentAway(error) else {
                    announce(PowerOutcome.explain(error), failure: true)
                    return
                }
                announce(underway, failure: false)
                session.stop()
            }
        }
    }
}
