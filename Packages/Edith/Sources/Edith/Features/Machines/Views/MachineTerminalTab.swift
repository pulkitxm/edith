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

@MainActor
@Observable
final class TerminalSessionHolder {
    private(set) var terminalView = EdithTerminalView.make()
    private(set) var generation = 0
    private(set) var started = false
    private(set) var exitMessage: String?
    private(set) var themeApplicationCount = 0
    private(set) var ghosttyLaunch: GhosttyLaunch?
    private(set) var ghosttyView: GhosttyTerminalView?
    private(set) var presentationGeneration = 0

    private var delegateBox: TerminalProcessDelegate?
    private var appliedPalette: TerminalPalette?
    private var presentationActive: Bool?
    private var presentationWantsFocus = false
    private var focusTask: Task<Void, Never>?

    func start(
        executable: String, arguments: [String], environment: [String],
        currentDirectory: String? = nil
    ) {
        guard !started else { return }
        started = true
        exitMessage = nil
        guard !GhosttyTerminals.enabled else {
            ghosttyLaunch = GhosttyLaunch(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: currentDirectory)
            return
        }
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
            executable: executable, args: arguments, environment: environment,
            currentDirectory: currentDirectory)
    }

    func reset() {
        presentationGeneration += 1
        focusTask?.cancel()
        focusTask = nil
        terminalView.terminal.resetToInitialState()
        if started { terminalView.terminate() }
        terminalView = EdithTerminalView.make()
        generation += 1
        started = false
        exitMessage = nil
        delegateBox = nil
        appliedPalette = nil
        presentationActive = nil
        presentationWantsFocus = false
        ghosttyView?.shutdown()
        ghosttyView = nil
        ghosttyLaunch = nil
    }

    func stop() {
        if started { terminalView.terminate() }
        ghosttyView?.shutdown()
        ghosttyView = nil
        ghosttyLaunch = nil
        started = false
    }

    func retainedGhosttyView(launch: GhosttyLaunch, theme: GhosttyTheme) -> GhosttyTerminalView {
        if let ghosttyView {
            ghosttyView.apply(theme: theme)
            return ghosttyView
        }
        let view = GhosttyTerminalView(launch: launch, theme: theme)
        view.onClose = { [weak self] in
            Task { @MainActor in
                self?.exitMessage = "Session ended."
                self?.started = false
            }
        }
        ghosttyView = view
        return view
    }

    func applyTheme(_ palette: TerminalPalette) {
        guard palette != appliedPalette else { return }
        TerminalFontRegistry.register()
        appliedPalette = palette
        themeApplicationCount += 1
        terminalView.configureNativeColors()
        terminalView.nativeBackgroundColor = palette.background
        terminalView.nativeForegroundColor = palette.foreground
        terminalView.caretColor = palette.caret
        terminalView.selectedTextBackgroundColor = palette.selectionBackground
        terminalView.selectedTextForegroundColor = palette.selectionForeground
        terminalView.terminal.ansi256PaletteStrategy = .base16LabHarmonious
        terminalView.installColors(palette.ansi.map(Self.swiftTermColor))
        terminalView.font = TerminalFontRegistry.monospacedFont(ofSize: 12.5)
    }

    private static func swiftTermColor(_ color: NSColor) -> SwiftTerm.Color {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return SwiftTerm.Color(
            red8: UInt16((resolved.redComponent * 255).rounded()),
            green8: UInt16((resolved.greenComponent * 255).rounded()),
            blue8: UInt16((resolved.blueComponent * 255).rounded()))
    }

    func updatePresentation(active: Bool, wantsFocus: Bool) {
        let wantsFocus = active && wantsFocus
        guard active != presentationActive || wantsFocus != presentationWantsFocus else { return }
        presentationActive = active
        presentationWantsFocus = wantsFocus
        terminalView.setRenderingActive(active)
        presentationGeneration += 1
        focusTask?.cancel()
        focusTask = nil
        guard active, wantsFocus else { return }
        let view = terminalView
        let generation = presentationGeneration
        focusTask = Task { @MainActor [weak self, weak view] in
            await Task.yield()
            guard !Task.isCancelled, let self, let view else { return }
            self.applyFocus(to: view, generation: generation)
        }
    }

    private func applyFocus(to view: EdithTerminalView, generation: Int) {
        guard generation == presentationGeneration,
            terminalView === view,
            presentationActive == true,
            presentationWantsFocus
        else { return }
        view.window?.makeFirstResponder(view)
        focusTask = nil
    }

    func registerOSCHandler(code: Int, handler: @escaping @MainActor (String) -> Void) {
        terminalView.terminal.registerOscHandler(code: code) { bytes in
            guard let payload = String(bytes: bytes, encoding: .utf8) else { return }
            Task { @MainActor in handler(payload) }
        }
    }

    func insertText(_ text: String) {
        if let ghosttyView {
            _ = ghosttyView.insertText(text)
        } else {
            terminalView.send(Array(text.utf8))
        }
    }
}

final class EdithTerminalView: LocalProcessTerminalView, DirectKeyboardInputResponder {
    static let scrollback = 10000

    static func make() -> EdithTerminalView {
        EdithTerminalView(
            frame: .zero, font: nil, options: TerminalOptions(scrollback: scrollback))
    }

    private(set) var renderingActive = true
    private(set) var deferredDisplayPasses = 0
    private(set) var reactivationDisplayPasses = 0
    private(set) var hasDeferredDisplay = false
    var onDropFiles: ((TerminalDropPayload) -> Bool)?
    private var temporaryDropFiles = Set<URL>()

    deinit {
        TerminalDropPayload(files: [], temporaryFiles: temporaryDropFiles).removeTemporaryFiles()
    }

    func setRenderingActive(_ active: Bool) {
        guard active != renderingActive else { return }
        renderingActive = active
        isHidden = !active
        guard active, hasDeferredDisplay else { return }
        hasDeferredDisplay = false
        reactivationDisplayPasses += 1
        super.needsDisplay = true
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            guard renderingActive || !newValue else {
                deferDisplay()
                return
            }
            super.needsDisplay = newValue
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard renderingActive else {
            deferDisplay()
            return
        }
        super.setNeedsDisplay(invalidRect)
    }

    private func deferDisplay() {
        guard !hasDeferredDisplay else { return }
        hasDeferredDisplay = true
        deferredDisplayPasses += 1
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch command(for: event) {
        case .newline:
            send([0x1b, 0x0d])
            return true
        case .copy:
            copy(self)
            return true
        case .paste:
            paste(self)
            return true
        case .none:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard TerminalDropPayload.canRead(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let payload = TerminalDropPayload.files(from: sender.draggingPasteboard) {
            return accept(payload)
        }
        let receivingPromises = TerminalDropPayload.receivePromisedFiles(
            from: sender.draggingPasteboard
        ) { [weak self] payload in
            _ = self?.accept(payload)
        }
        if receivingPromises { return true }
        if let rawURL = sender.draggingPasteboard.string(forType: .URL), !rawURL.isEmpty {
            send(Array(GhosttyTerminalView.quote(rawURL).utf8))
            return true
        }
        guard let text = sender.draggingPasteboard.string(forType: .string), !text.isEmpty else {
            return super.performDragOperation(sender)
        }
        send(Array(text.utf8))
        return true
    }

    private func accept(_ payload: TerminalDropPayload) -> Bool {
        if onDropFiles?(payload) == true { return true }
        temporaryDropFiles.formUnion(payload.temporaryFiles)
        send(Array(payload.shellText.utf8))
        return true
    }

    enum DirectCommand {
        case newline
        case copy
        case paste
        case none
    }

    func command(for event: NSEvent) -> DirectCommand {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .shift, event.keyCode == 36 || event.keyCode == 76 {
            return getTerminal().keyboardEnhancementFlags.isEmpty ? .newline : .none
        }
        guard flags == .command else { return .none }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return selectionActive ? .copy : .none
        case "v": return .paste
        default: return .none
        }
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

struct TerminalPane: View {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var onDropFiles: ((TerminalDropPayload) -> Bool)?

    var body: some View {
        if GhosttyTerminals.enabled {
            if let launch = holder.ghosttyLaunch {
                GhosttyPane(
                    holder: holder, launch: launch, theme: GhosttyTheme(palette: palette),
                    active: active, wantsFocus: wantsFocus, onDropFiles: onDropFiles)
            }
        } else {
            SwiftTermPane(
                holder: holder, palette: palette, active: active, wantsFocus: wantsFocus,
                onDropFiles: onDropFiles)
        }
    }
}

struct SwiftTermPane: NSViewRepresentable {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true
    var onDropFiles: ((TerminalDropPayload) -> Bool)?

    func makeNSView(context: Context) -> EdithTerminalView {
        holder.applyTheme(palette)
        holder.updatePresentation(active: active, wantsFocus: wantsFocus)
        let view = holder.terminalView
        view.onDropFiles = onDropFiles
        view.registerForDraggedTypes(TerminalDropPayload.pasteboardTypes)
        return view
    }

    func updateNSView(_ view: EdithTerminalView, context: Context) {
        holder.applyTheme(palette)
        holder.updatePresentation(active: active, wantsFocus: wantsFocus)
        view.onDropFiles = onDropFiles
    }
}

struct MachineTerminalTab: View {
    let session: MachineSession
    var active = true
    var wantsFocus = true
    @State private var ownHolder = TerminalSessionHolder()
    private let injectedHolder: TerminalSessionHolder?
    private let context: MachineTerminalContext?
    private let showsStatusBar: Bool

    init(
        session: MachineSession, active: Bool = true, wantsFocus: Bool = true,
        context: MachineTerminalContext? = nil,
        showsStatusBar: Bool = true,
        holder: TerminalSessionHolder? = nil
    ) {
        self.session = session
        self.active = active
        self.wantsFocus = wantsFocus
        injectedHolder = holder
        self.context = context
        self.showsStatusBar = showsStatusBar
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
                    wantsFocus: wantsFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let action = presentation.action {
                Button(action.title) { perform(action) }
                    .font(.system(size: UIScale.pt(11)))
            }
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(8))
    }

    private func terminalUnavailable(_ presentation: MachineTerminalPresentation) -> some View {
        VStack(spacing: UIScale.pt(10)) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: presentation.symbol)
                    .font(.system(size: UIScale.pt(24), weight: .light))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
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
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                context: context, platform: session.remotePlatform ?? .linux)
        else { return }
        holder.start(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment, currentDirectory: launch.currentDirectory)
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
                + connection.terminalEnvironment())
    }

    private func startWindowsShell() {
        guard session.state.isConnected, let connection = session.connectionRef else { return }
        let command = WindowsTerminalCommands.interactiveShell()
        holder.start(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(remoteCommand: command),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                + connection.terminalEnvironment())
    }

    private func restart() {
        holder.stop()
        startIfPossible()
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
        platform: RemoteMachinePlatform = .linux
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
                startingDirectory: context.startingDirectory)
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
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
        holder.start(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment)
    }
}
