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
    private(set) var terminalView = EdithTerminalView.make()
    private(set) var generation = 0
    private(set) var started = false
    private(set) var exitMessage: String?
    private(set) var themeApplicationCount = 0
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
    }

    func stop() {
        guard started else { return }
        terminalView.terminate()
        started = false
    }

    func applyTheme(_ palette: TerminalPalette) {
        guard palette != appliedPalette else { return }
        appliedPalette = palette
        themeApplicationCount += 1
        terminalView.configureNativeColors()
        terminalView.nativeBackgroundColor = palette.background
        terminalView.nativeForegroundColor = palette.foreground
        terminalView.caretColor = palette.caret
        terminalView.terminal.ansi256PaletteStrategy = .base16LabHarmonious
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
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

struct TerminalPane: NSViewRepresentable {
    let holder: TerminalSessionHolder
    let palette: TerminalPalette
    var active = true
    var wantsFocus = true

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        holder.applyTheme(palette)
        holder.updatePresentation(active: active, wantsFocus: wantsFocus)
        let view = holder.terminalView
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        holder.applyTheme(palette)
        holder.updatePresentation(active: active, wantsFocus: wantsFocus)
    }
}

struct MachineTerminalTab: View {
    let session: MachineSession
    var active = true
    var wantsFocus = true
    @State private var ownHolder = TerminalSessionHolder()
    private let injectedHolder: TerminalSessionHolder?

    init(
        session: MachineSession, active: Bool = true, wantsFocus: Bool = true,
        holder: TerminalSessionHolder? = nil
    ) {
        self.session = session
        self.active = active
        self.wantsFocus = wantsFocus
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
            TerminalPane(
                holder: holder, palette: .edith(dark: dark), active: active,
                wantsFocus: wantsFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(dark ? Color.black.opacity(0.9) : Color.white)
        .onAppear(perform: startIfPossible)
        .onChange(of: active) { _, active in
            if active { startIfPossible() }
        }
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
        guard
            TerminalLaunchPolicy.shouldStart(
                active: active, launchEnabled: launchEnabled, started: holder.started,
                isLocal: session.isLocal, connected: session.state.isConnected)
        else { return }
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
                    .pointerCursor()
            }
            .padding(UIScale.pt(14))
            Divider()
            TerminalPane(holder: holder, palette: .edith(dark: dark))
        }
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
