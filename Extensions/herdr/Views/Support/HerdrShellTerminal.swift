import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor enum HerdrTerminalMachines {
    static var shared: Self { .inventory }
    case inventory
    func knows(_ id: UUID) -> Bool {
        id == Machine.localID || MachineRegistry.machines().contains { $0.id == id }
    }
}

struct HerdrShellTerminal: View {
    let target: PaneTarget
    let holder: TerminalSessionHolder
    let active: Bool
    let wantsFocus: Bool
    let launchEnabled: Bool
    var onFocus: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var error: String?
    var body: some View {
        ZStack {
            TerminalPane(
                holder: holder, palette: .edith(dark: scheme == .dark), active: active,
                wantsFocus: wantsFocus, onFocus: onFocus)
            if let error {
                VStack(spacing: UIScale.pt(10)) {
                    Text(error).font(.edithText(.body)).textSelection(.enabled)
                    Button("Retry") {
                        self.error = nil; holder.reset()
                    }.buttonStyle(.edith(.secondary))
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(
                    DashSkin.paper(scheme == .dark))
            }
        }
        .task(id: active && launchEnabled && error == nil) {
            guard active, launchEnabled, error == nil, !holder.started else { return }
            do {
                let request: TerminalLaunchRequest
                if target.machineID == Machine.localID {
                    request = TerminalLaunchRequest(
                        executable: "/bin/zsh", arguments: ["-l"],
                        environment: CLIToolEnvironment.sanitized().map { "\($0.key)=\($0.value)" })
                } else {
                    guard
                        let machine = MachineRegistry.machines().first(where: {
                            $0.id == target.machineID
                        })
                    else { throw ExtensionPeerError.unavailable }
                    let connection = SSHConnection(machine: machine)
                    try await connection.connect()
                    let command = target.argument.map {
                        "cd -- " + POSIXQuote.quote($0) + " && exec \"$SHELL\" -l"
                    }
                    request = TerminalLaunchRequest(
                        executable: SSHConnection.executable.path,
                        arguments: try connection.terminalArguments(remoteCommand: command),
                        environment: connection.terminalEnvironment())
                }
                try Task.checkCancellation()
                guard let host = HerdrTerminalBridge.executable() else {
                    throw HerdrTerminalBridgeError.executableUnavailable
                }
                let native = try HerdrTerminalBridge.launchRequest(
                    bridgeExecutable: host, controller: request, transport: .terminal)
                holder.start(
                    executable: native.executable, arguments: native.arguments,
                    environment: native.environment,
                    currentDirectory: target.machineID == Machine.localID ? target.argument : nil,
                    allowsLocalFileLinks: target.machineID == Machine.localID)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
