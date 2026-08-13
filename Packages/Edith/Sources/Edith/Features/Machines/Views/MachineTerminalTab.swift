import AppKit
import EdithKit
import Observation
import SwiftTerm
import SwiftUI

private struct TerminalLaunchEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var terminalLaunchEnabled: Bool {
        get { self[TerminalLaunchEnabledKey.self] }
        set { self[TerminalLaunchEnabledKey.self] = newValue }
    }
}

@MainActor
@Observable
final class TerminalSessionHolder {
    let terminalView = LocalProcessTerminalView(frame: .zero)
    private(set) var started = false
    private(set) var exitMessage: String?

    private var delegateBox: TerminalProcessDelegate?

    func start(executable: String, arguments: [String], environment: [String]) {
        guard !started else { return }
        started = true
        exitMessage = nil
        let delegate = TerminalProcessDelegate { [weak self] code in
            Task { @MainActor in
                self?.exitMessage =
                    code == nil || code == 0
                    ? "Session ended." : "Session ended with status \(code ?? 0)."
                self?.started = false
            }
        }
        delegateBox = delegate
        terminalView.processDelegate = delegate
        terminalView.startProcess(
            executable: executable, args: arguments, environment: environment)
    }

    func restart(executable: String, arguments: [String], environment: [String]) {
        terminalView.terminate()
        started = false
        start(executable: executable, arguments: arguments, environment: environment)
    }

    func stop() {
        guard started else { return }
        terminalView.terminate()
        started = false
    }

    func applyTheme(dark: Bool) {
        terminalView.configureNativeColors()
        terminalView.nativeBackgroundColor =
            dark
            ? NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.07, alpha: 1) : .white
        terminalView.nativeForegroundColor =
            dark
            ? NSColor(calibratedRed: 0.92, green: 0.9, blue: 0.86, alpha: 1) : .black
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }
}

private final class TerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private let onExit: (Int32?) -> Void

    init(onExit: @escaping (Int32?) -> Void) {
        self.onExit = onExit
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit(exitCode)
    }
}

struct TerminalPane: NSViewRepresentable {
    let holder: TerminalSessionHolder
    let dark: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        holder.applyTheme(dark: dark)
        let view = holder.terminalView
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        holder.applyTheme(dark: dark)
    }
}

struct MachineTerminalTab: View {
    let session: MachineSession
    @State private var ownHolder = TerminalSessionHolder()
    private let injectedHolder: TerminalSessionHolder?

    init(session: MachineSession, holder: TerminalSessionHolder? = nil) {
        self.session = session
        injectedHolder = holder
    }

    private var holder: TerminalSessionHolder { injectedHolder ?? ownHolder }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            TerminalPane(holder: holder, dark: dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(dark ? Color.black.opacity(0.9) : Color.white)
        .onAppear(perform: startIfPossible)
        .onChange(of: session.state.isConnected) { _, connected in
            if connected { startIfPossible() }
        }
        .onDisappear { if injectedHolder == nil { holder.stop() } }
    }

    private var statusBar: some View {
        HStack(spacing: UIScale.pt(10)) {
            Text(session.isLocal ? "Local shell" : "SSH · \(session.machine.sshTarget)")
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.inkFaint(dark))
            if let message = holder.exitMessage {
                Text(message)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.warn)
            }
            Spacer(minLength: 0)
            Button(holder.started ? "Restart" : "Start") { restart() }
                .pointerCursor()
                .font(.system(size: UIScale.pt(11)))
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(8))
    }

    private func startIfPossible() {
        guard launchEnabled, !holder.started else { return }
        if session.isLocal {
            holder.start(
                executable: "/bin/zsh", arguments: ["-l"],
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
            return
        }
        guard session.state.isConnected, let connection = session.connectionRef else { return }
        holder.start(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                + connection.terminalEnvironment())
    }

    private func restart() {
        holder.stop()
        startIfPossible()
    }
}

struct ContainerTerminalSheet: View {
    let session: MachineSession
    let container: DockerContainer
    @State private var holder = TerminalSessionHolder()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shell in \(container.displayName)")
                    .font(DashSkin.serif(17))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                if let message = holder.exitMessage {
                    Text(message)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.warn)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
            .padding(UIScale.pt(14))
            Divider()
            TerminalPane(holder: holder, dark: dark)
        }
        .frame(width: UIScale.pt(760), height: UIScale.pt(520))
        .onAppear(perform: start)
        .onDisappear { holder.stop() }
    }

    private func start() {
        guard launchEnabled else { return }
        guard let connection = session.connectionRef else { return }
        let command = DockerCommands.execShell(containerID: container.id)
        holder.start(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(remoteCommand: command),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                + connection.terminalEnvironment())
    }
}
