import AppKit
import EdithKit
import GhosttyTerminal
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

struct MachineTerminalTab: View {
    let session: MachineSession
    var active = true
    var wantsFocus = true
    var allowsShellLaunch = true
    var onFocus: (() -> Void)?
    @State private var ownHolder = TerminalSessionHolder()
    @State private var selectedWindowsShell = WindowsTerminalShell.automatic
    @State private var availableWindowsShells = [WindowsTerminalShell.automatic]
    @State private var detectingWindowsShells = false
    private let injectedHolder: TerminalSessionHolder?
    private let context: MachineTerminalContext?
    private let showsStatusBar: Bool

    init(
        session: MachineSession, active: Bool = true, wantsFocus: Bool = true,
        context: MachineTerminalContext? = nil,
        showsStatusBar: Bool = true,
        onFocus: (() -> Void)? = nil,
        holder: TerminalSessionHolder? = nil,
        allowsShellLaunch: Bool = true
    ) {
        self.session = session
        self.active = active
        self.wantsFocus = wantsFocus
        self.allowsShellLaunch = allowsShellLaunch
        injectedHolder = holder
        self.context = context
        self.showsStatusBar = showsStatusBar
        self.onFocus = onFocus
    }

    private var holder: TerminalSessionHolder { injectedHolder ?? ownHolder }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.terminalLaunchEnabled) private var launchEnabled

    private var dark: Bool { scheme == .dark }
    private var shellLaunchEnabled: Bool { allowsShellLaunch && launchEnabled }

    var body: some View {
        let presentation = MachineTerminalPresentation.make(
            state: session.state, target: session.machine.sshTarget, isLocal: session.isLocal,
            started: holder.started, exitMessage: holder.exitMessage,
            launchEnabled: shellLaunchEnabled)
        VStack(spacing: 0) {
            if showsStatusBar { statusBar(presentation) }
            if presentation.showsTerminal {
                TerminalPane(
                    holder: holder, palette: .edith(dark: dark), active: active,
                    wantsFocus: wantsFocus,
                    onDropFiles: session.isLocal ? nil : uploadDrop,
                    onFocus: onFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { TerminalDropTransferStatus(holder: holder) }
            } else {
                terminalUnavailable(presentation)
            }
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .onAppear(perform: startIfPossible)
        .onChange(of: active) { _, active in
            if active { startIfPossible() }
        }
        .onChange(of: session.state.isConnected) { _, connected in
            if connected { startIfPossible() }
        }
        .task(id: session.state.isConnected) {
            await detectWindowsShells()
        }
        .onDisappear { if injectedHolder == nil { holder.stop() } }
    }

    private func statusBar(_ presentation: MachineTerminalPresentation) -> some View {
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
            if session.remotePlatform == .windows {
                windowsShellMenu
            }
            if let action = presentation.action {
                Button(action.title) { perform(action) }
                    .font(.system(size: UIScale.pt(11)))
            }
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(8))
    }

    private var windowsShellMenu: some View {
        Menu {
            ForEach(availableWindowsShells) { shell in
                Button {
                    selectWindowsShell(shell)
                } label: {
                    if shell == selectedWindowsShell {
                        Label(shell.label, systemImage: "checkmark")
                    } else {
                        Text(shell.label)
                    }
                }
            }
            if detectingWindowsShells {
                Divider()
                SkeletonGroup {
                    SkeletonBlock(width: 142, height: 9, corner: 2)
                        .frame(height: UIScale.pt(18))
                }
                .accessibilityLabel("Detecting installed shells")
            }
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: "terminal")
                Text(selectedWindowsShell.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: UIScale.pt(8), weight: .semibold))
            }
            .font(DashSkin.mono(11))
            .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the shell for this terminal")
    }

    private func terminalUnavailable(_ presentation: MachineTerminalPresentation) -> some View {
        Group {
            if presentation.showsProgress {
                TerminalLoadingSkeleton(palette: .edith(dark: dark))
            } else {
                VStack(spacing: UIScale.pt(10)) {
                    Image(systemName: presentation.symbol)
                        .font(.system(size: UIScale.pt(24), weight: .light))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Text(presentation.title)
                        .font(.system(size: UIScale.pt(14), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: UIScale.pt(520))
                    }
                    if let action = presentation.action {
                        Button(action.title) { perform(action) }
                            .buttonStyle(.edith(.primary))
                    }
                }
                .padding(UIScale.pt(24))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startIfPossible() {
        guard
            TerminalLaunchPolicy.shouldStart(
                active: active, launchEnabled: shellLaunchEnabled, started: holder.started,
                isLocal: session.isLocal, connected: session.state.isConnected)
        else { return }
        guard let context else {
            if !session.isLocal, session.remotePlatform == .windows {
                startWindowsShell()
                return
            }
            startStandardShell()
            return
        }
        let connection = session.isLocal ? nil : session.connectionRef
        guard
            let launch = MachineTerminalLaunchPlan.make(
                isLocal: session.isLocal, connection: connection,
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                context: context, platform: session.remotePlatform ?? .linux,
                windowsShell: selectedWindowsShell)
        else { return }
        holder.start(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment, currentDirectory: launch.currentDirectory,
            allowsLocalFileLinks: session.isLocal)
    }

    private func startStandardShell() {
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
                + connection.terminalEnvironment(),
            allowsLocalFileLinks: false)
    }

    private func startWindowsShell() {
        guard session.state.isConnected, let connection = session.connectionRef else { return }
        let command = WindowsTerminalCommands.interactiveShell(selectedWindowsShell)
        holder.start(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(remoteCommand: command),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                + connection.terminalEnvironment(),
            allowsLocalFileLinks: false)
    }

    private func detectWindowsShells() async {
        guard session.state.isConnected, session.remotePlatform == .windows,
            let connection = session.connectionRef
        else {
            availableWindowsShells = [.automatic]
            detectingWindowsShells = false
            return
        }
        detectingWindowsShells = true
        defer { detectingWindowsShells = false }
        guard
            let result = try? await connection.run(
                WindowsTerminalCommands.availableShells(), timeout: 10),
            result.succeeded
        else { return }
        availableWindowsShells =
            [.automatic]
            + WindowsTerminalCommands.parseAvailableShells(result.stdoutText)
    }

    private func selectWindowsShell(_ shell: WindowsTerminalShell) {
        guard shell != selectedWindowsShell else { return }
        selectedWindowsShell = shell
        guard holder.started else {
            startIfPossible()
            return
        }
        holder.reset()
        startIfPossible()
    }

    private func restart() {
        holder.reset()
        startIfPossible()
    }

    private func uploadDrop(_ payload: TerminalDropPayload) -> Bool {
        guard let connection = session.connectionRef else { return false }
        Task {
            await holder.deliverRemoteDrop(payload) { files in
                try await TerminalDropTransfer.upload(files, over: connection)
            }
        }
        return true
    }

    private func perform(_ action: MachineTerminalAction) {
        switch action {
        case .start: startIfPossible()
        case .restart: restart()
        case .connect: session.start()
        case .retry: session.retry()
        }
    }
}

struct MachineTerminalContext: Equatable, Sendable {
    let startingDirectory: String?

    init(startingDirectory: String? = nil) {
        let trimmed = startingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startingDirectory = trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct MachineTerminalLaunch: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let currentDirectory: String?
}

enum MachineTerminalLaunchPlan {
    static let remoteLoginShell = "exec \"${SHELL:-/bin/sh}\" -l"

    static func make(
        isLocal: Bool, connection: SSHConnection?, environment: [String],
        context: MachineTerminalContext = MachineTerminalContext(),
        platform: RemoteMachinePlatform = .linux,
        windowsShell: WindowsTerminalShell = .automatic
    ) -> MachineTerminalLaunch? {
        if isLocal {
            return MachineTerminalLaunch(
                executable: "/bin/zsh", arguments: ["-l"],
                environment: HerdrMachineTerminal.unnested(environment),
                currentDirectory: context.startingDirectory)
        }
        guard let connection else { return nil }
        let command: String
        if platform == .windows {
            command = WindowsTerminalCommands.interactiveShell(
                windowsShell, startingDirectory: context.startingDirectory)
        } else {
            command = MachineWorkingDirectory.prefixed(
                remoteLoginShell, directory: context.startingDirectory)
        }
        return MachineTerminalLaunch(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(remoteCommand: command),
            environment: HerdrMachineTerminal.unnested(
                environment + connection.terminalEnvironment()),
            currentDirectory: nil)
    }
}

enum MachineTerminalAction: Equatable {
    case start
    case restart
    case connect
    case retry

    var title: String {
        switch self {
        case .start: return "Start"
        case .restart: return "Restart"
        case .connect: return "Connect"
        case .retry: return "Retry"
        }
    }
}

struct MachineTerminalPresentation: Equatable {
    let title: String
    let detail: String?
    let symbol: String
    let showsProgress: Bool
    let showsTerminal: Bool
    let action: MachineTerminalAction?

    static func make(
        state: MachineConnectionState, target: String, isLocal: Bool, started: Bool,
        exitMessage: String?, launchEnabled: Bool
    ) -> MachineTerminalPresentation {
        if started {
            return MachineTerminalPresentation(
                title: "Terminal running", detail: nil, symbol: "terminal",
                showsProgress: false, showsTerminal: true,
                action: launchEnabled ? .restart : nil)
        }
        if isLocal {
            if let exitMessage {
                return MachineTerminalPresentation(
                    title: "Terminal session ended", detail: exitMessage, symbol: "terminal",
                    showsProgress: false, showsTerminal: false,
                    action: launchEnabled ? .start : nil)
            }
            return MachineTerminalPresentation(
                title: "Starting local shell…", detail: nil, symbol: "terminal",
                showsProgress: true, showsTerminal: false, action: nil)
        }
        switch state {
        case .disconnected:
            return MachineTerminalPresentation(
                title: "Not connected", detail: "Connect to \(target) to start a terminal.",
                symbol: "network.slash", showsProgress: false, showsTerminal: false,
                action: .connect)
        case .connecting:
            return MachineTerminalPresentation(
                title: "Connecting to \(target)…", detail: nil, symbol: "network",
                showsProgress: true, showsTerminal: false, action: nil)
        case let .reconnecting(message):
            return MachineTerminalPresentation(
                title: "Reconnecting to \(target)…", detail: message, symbol: "network",
                showsProgress: true, showsTerminal: false, action: nil)
        case .connected:
            if let exitMessage {
                return MachineTerminalPresentation(
                    title: "Terminal session ended", detail: exitMessage, symbol: "terminal",
                    showsProgress: false, showsTerminal: false,
                    action: launchEnabled ? .start : nil)
            }
            return MachineTerminalPresentation(
                title: "Starting terminal…", detail: nil, symbol: "terminal",
                showsProgress: true, showsTerminal: false, action: nil)
        case let .failed(message, recoverable):
            return MachineTerminalPresentation(
                title: "Couldn’t connect to \(target)", detail: message,
                symbol: "exclamationmark.triangle", showsProgress: false,
                showsTerminal: false, action: recoverable ? .retry : nil)
        }
    }
}

enum TerminalLaunchPolicy {
    static func shouldStart(
        active: Bool, launchEnabled: Bool, started: Bool, isLocal: Bool, connected: Bool
    ) -> Bool {
        active && launchEnabled && !started && (isLocal || connected)
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
                    .font(DashSkin.heading(17))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                if let message = holder.exitMessage {
                    Text(message)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.warn)
                }
                Button("Done") {
                    holder.requestUserClose { accepted in
                        if accepted { dismiss() }
                    }
                }
                .buttonStyle(.edith(.secondary))
            }
            .padding(UIScale.pt(14))
            Divider()
            TerminalPane(holder: holder, palette: .edith(dark: dark))
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .frame(width: PresentationMetrics.width(760), height: PresentationMetrics.height(520))
        .onAppear(perform: start)
        .onDisappear { holder.stop() }
    }

    private func start() {
        guard launchEnabled else { return }
        guard let connection = session.connectionRef else { return }
        let launch = MachineExecOperationExecution.dockerShellLaunch(
            containerID: container.id, connection: connection,
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
        holder.start(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment, allowsLocalFileLinks: session.isLocal)
    }
}
