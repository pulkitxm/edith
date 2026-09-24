import AppKit
import EdithKit
import GhosttyTerminal
import Observation
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
    typealias GhosttyInputDelivery = @MainActor (GhosttyTerminalView, String) -> Bool
    typealias GhosttyCloseRequest = @MainActor (GhosttyTerminalView) -> Bool

    private struct PendingUserClose {
        let viewID: ObjectIdentifier
        let generation: Int
        let completion: @MainActor (Bool) -> Void
    }

    private(set) var generation = 0
    private(set) var started = false
    private(set) var exitMessage: String?
    private(set) var currentTitle: String?
    private(set) var currentWorkingDirectory: String?
    private(set) var ghosttyLaunch: GhosttyLaunch?
    private(set) var ghosttyView: GhosttyTerminalView?
    private(set) var transferringDrop = false
    private(set) var dropTransferError: String?

    private var queuedGhosttyInput = ""
    private var pendingUserClose: PendingUserClose?
    private let requestGhosttyClose: GhosttyCloseRequest
    private let deliverGhosttyInput: GhosttyInputDelivery

    init(
        requestGhosttyClose: @escaping GhosttyCloseRequest = { view in view.requestClose() },
        deliverGhosttyInput: @escaping GhosttyInputDelivery = { view, text in
            view.insertText(text)
        }
    ) {
        self.requestGhosttyClose = requestGhosttyClose
        self.deliverGhosttyInput = deliverGhosttyInput
    }

    func start(
        executable: String, arguments: [String], environment: [String],
        currentDirectory: String? = nil, allowsLocalFileLinks: Bool = true,
        resetTerminalAfterInterrupt: Bool = false
    ) {
        guard !started else { return }
        clearQueuedGhosttyInput()
        started = true
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = currentDirectory
        ghosttyLaunch = GhosttyLaunch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: currentDirectory, allowsLocalFileLinks: allowsLocalFileLinks,
            resetTerminalAfterInterrupt: resetTerminalAfterInterrupt)
    }

    func reset() {
        pendingUserClose = nil
        clearQueuedGhosttyInput()
        generation += 1
        started = false
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = nil
        ghosttyView?.shutdown()
        ghosttyView = nil
        ghosttyLaunch = nil
    }

    func stop() {
        reset()
    }

    func requestUserClose(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard pendingUserClose == nil else {
            completion(false)
            return
        }
        guard let ghosttyView else {
            stop()
            completion(true)
            return
        }
        let request = PendingUserClose(
            viewID: ObjectIdentifier(ghosttyView), generation: generation,
            completion: completion)
        pendingUserClose = request
        guard requestGhosttyClose(ghosttyView) else {
            pendingUserClose = nil
            stop()
            completion(true)
            return
        }
    }

    func sendInput(_ text: String) {
        sendGhosttyInput(text)
    }

    func retainedGhosttyView(launch: GhosttyLaunch, theme: GhosttyTheme) -> GhosttyTerminalView {
        if let ghosttyView {
            ghosttyView.apply(theme: theme)
            flushQueuedGhosttyInput(to: ghosttyView)
            return ghosttyView
        }
        let view = GhosttyTerminalView(launch: launch, theme: theme)
        let viewGeneration = generation
        view.onClose = { [weak self, weak view] exitCode in
            Task { @MainActor in
                guard let self, let view, self.generation == viewGeneration,
                    self.ghosttyView === view
                else { return }
                self.finishGhosttySession(view, exitCode: exitCode)
            }
        }
        view.onTitleChange = { [weak self] title in
            Task { @MainActor in
                self?.setCurrentTitle(title, generation: viewGeneration)
            }
        }
        view.onWorkingDirectoryChange = { [weak self] directory in
            Task { @MainActor in
                self?.setCurrentWorkingDirectory(directory, generation: viewGeneration)
            }
        }
        view.onReady = { [weak self, weak view] in
            guard let self, let view, self.generation == viewGeneration else { return }
            self.flushQueuedGhosttyInput(to: view)
        }
        ghosttyView = view
        flushQueuedGhosttyInput(to: view)
        return view
    }

    private func finishGhosttySession(_ view: GhosttyTerminalView, exitCode: Int32?) {
        let closeCompletion = takeUserCloseCompletion(for: view, generation: generation)
        clearQueuedGhosttyInput()
        view.shutdown()
        ghosttyView = nil
        ghosttyLaunch = nil
        generation += 1
        started = false
        currentTitle = nil
        currentWorkingDirectory = nil
        exitMessage =
            exitCode == nil || exitCode == 0
            ? "Session ended." : "Session ended with status \(exitCode ?? 0)."
        closeCompletion?(true)
    }

    private func takeUserCloseCompletion(
        for view: GhosttyTerminalView, generation: Int
    ) -> (@MainActor (Bool) -> Void)? {
        guard let request = pendingUserClose,
            request.viewID == ObjectIdentifier(view), request.generation == generation
        else { return nil }
        pendingUserClose = nil
        return request.completion
    }

    private func setCurrentTitle(_ title: String?, generation: Int) {
        guard self.generation == generation else { return }
        currentTitle = title?.isEmpty == false ? title : nil
    }

    private func setCurrentWorkingDirectory(_ directory: String?, generation: Int) {
        guard self.generation == generation else { return }
        currentWorkingDirectory = directory?.isEmpty == false ? directory : nil
    }

    private func sendGhosttyInput(_ text: String) {
        guard !text.isEmpty else { return }
        if let ghosttyView, queuedGhosttyInput.isEmpty,
            deliverGhosttyInput(ghosttyView, text)
        {
            return
        }
        queuedGhosttyInput += text
        if let ghosttyView { flushQueuedGhosttyInput(to: ghosttyView) }
    }

    private func flushQueuedGhosttyInput(to view: GhosttyTerminalView) {
        guard ghosttyView === view, !queuedGhosttyInput.isEmpty else { return }
        let input = queuedGhosttyInput
        guard deliverGhosttyInput(view, input) else { return }
        queuedGhosttyInput = ""
    }

    private func clearQueuedGhosttyInput() {
        queuedGhosttyInput = ""
    }

    func insertText(_ text: String) {
        sendGhosttyInput(text)
    }

    func deliverRemoteDrop(
        _ payload: TerminalDropPayload, upload: ([URL]) async throws -> [String]
    ) async {
        transferringDrop = true
        dropTransferError = nil
        defer {
            transferringDrop = false
            payload.removeTemporaryFiles()
        }
        do {
            let paths = try await upload(payload.files)
            insertText(paths.map(ShellQuote.quote).joined(separator: " "))
        } catch {
            dropTransferError = error.localizedDescription
        }
    }
}

struct TerminalPane: View {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    var onFocus: (() -> Void)?

    var body: some View {
        if let launch = holder.ghosttyLaunch {
            GhosttyPane(
                holder: holder, launch: launch, theme: GhosttyTheme(palette: palette),
                active: active, wantsFocus: wantsFocus, onDropFiles: onDropFiles,
                onFocus: onFocus
            )
            .id(holder.generation)
        }
    }
}

enum TerminalEnvironment {
    static func defaults(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8"]
            + ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "HOME"].compactMap { key in
                processEnvironment[key].map { "\(key)=\($0)" }
            }
    }
}

struct MachineTerminalTab: View {
    let session: MachineSession
    var active = true
    var wantsFocus = true
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
        holder: TerminalSessionHolder? = nil
    ) {
        self.session = session
        self.active = active
        self.wantsFocus = wantsFocus
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

    var body: some View {
        let presentation = MachineTerminalPresentation.make(
            state: session.state, target: session.machine.sshTarget, isLocal: session.isLocal,
            started: holder.started, exitMessage: holder.exitMessage,
            launchEnabled: launchEnabled)
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
                active: active, launchEnabled: launchEnabled, started: holder.started,
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
                environment: TerminalEnvironment.defaults(),
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
                environment: TerminalEnvironment.defaults())
            return
        }
        guard session.state.isConnected, let connection = session.connectionRef else { return }
        holder.start(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(),
            environment: TerminalEnvironment.defaults()
                + connection.terminalEnvironment(),
            allowsLocalFileLinks: false)
    }

    private func startWindowsShell() {
        guard session.state.isConnected, let connection = session.connectionRef else { return }
        let command = WindowsTerminalCommands.interactiveShell(selectedWindowsShell)
        holder.start(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(remoteCommand: command),
            environment: TerminalEnvironment.defaults()
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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(UIScale.pt(14))
            Divider()
            TerminalPane(holder: holder, palette: .edith(dark: dark))
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .frame(width: UIScale.pt(760), height: UIScale.pt(520))
        .onAppear(perform: start)
        .onDisappear { holder.stop() }
    }

    private func start() {
        guard launchEnabled else { return }
        guard let connection = session.connectionRef else { return }
        let launch = MachineExecOperationExecution.dockerShellLaunch(
            containerID: container.id, connection: connection,
            environment: TerminalEnvironment.defaults())
        holder.start(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment, allowsLocalFileLinks: session.isLocal)
    }
}
