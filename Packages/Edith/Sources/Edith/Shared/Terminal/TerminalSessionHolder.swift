import AppKit
import EdithKit
import GhosttyTerminal
import Observation
import SwiftTerm
import SwiftUI

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

    @ObservationIgnored private var swiftTermView: EdithTerminalView?
    @ObservationIgnored private var oscHandlers: [Int: @MainActor (String) -> Void] = [:]
    private(set) var generation = 0
    private(set) var started = false
    private(set) var exitMessage: String?
    private(set) var currentTitle: String?
    private(set) var currentWorkingDirectory: String?
    private(set) var themeApplicationCount = 0
    private(set) var ghosttyLaunch: GhosttyLaunch?
    private(set) var ghosttyView: GhosttyTerminalView?
    private(set) var presentationGeneration = 0
    private(set) var transferringDrop = false
    private(set) var dropTransferError: String?

    private var delegateBox: TerminalProcessDelegate?
    private var appliedPalette: TerminalPalette?
    private var presentationActive: Bool?
    private var presentationWantsFocus = false
    private var focusTask: Task<Void, Never>?
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
        guard !GhosttyTerminals.enabled else {
            ghosttyLaunch = GhosttyLaunch(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: currentDirectory, allowsLocalFileLinks: allowsLocalFileLinks,
                resetTerminalAfterInterrupt: resetTerminalAfterInterrupt)
            return
        }
        let delegateGeneration = generation
        let delegate = TerminalProcessDelegate(
            onExit: { [weak self] code in
                Task { @MainActor in
                    guard let self, self.generation == delegateGeneration else { return }
                    self.exitMessage =
                        code == nil || code == 0
                        ? "Session ended." : "Session ended with status \(code ?? 0)."
                    self.started = false
                }
            },
            onTitle: { [weak self] title in
                Task { @MainActor in
                    self?.setCurrentTitle(title, generation: delegateGeneration)
                }
            },
            onWorkingDirectory: { [weak self] directory in
                Task { @MainActor in
                    self?.setCurrentWorkingDirectory(directory, generation: delegateGeneration)
                }
            })
        delegateBox = delegate
        terminalView.processDelegate = delegate
        terminalView.startProcess(
            executable: executable, args: arguments, environment: environment,
            currentDirectory: currentDirectory)
    }

    func reset() {
        pendingUserClose = nil
        presentationGeneration += 1
        focusTask?.cancel()
        focusTask = nil
        if let swiftTermView {
            swiftTermView.terminal.resetToInitialState()
            if started { swiftTermView.terminate() }
        }
        clearQueuedGhosttyInput()
        swiftTermView = nil
        generation += 1
        started = false
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = nil
        delegateBox = nil
        appliedPalette = nil
        presentationActive = nil
        presentationWantsFocus = false
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
        if ghosttyLaunch != nil {
            sendGhosttyInput(text)
        } else {
            terminalView.send(txt: text)
        }
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
        focusTask?.cancel()
        focusTask = nil
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

    private var appliedFontSize = 0.0

    func applyTheme(_ palette: TerminalPalette, scale: Double = 1) {
        let fontSize = 12.5 * scale
        guard palette != appliedPalette || abs(fontSize - appliedFontSize) > 0.01 else { return }
        TerminalFontRegistry.register()
        appliedPalette = palette
        appliedFontSize = fontSize
        themeApplicationCount += 1
        terminalView.configureNativeColors()
        terminalView.nativeBackgroundColor = palette.background
        terminalView.nativeForegroundColor = palette.foreground
        terminalView.caretColor = palette.caret
        terminalView.selectedTextBackgroundColor = palette.selectionBackground
        terminalView.selectedTextForegroundColor = palette.selectionForeground
        terminalView.terminal.ansi256PaletteStrategy = .base16LabHarmonious
        terminalView.installColors(palette.ansi.map(Self.swiftTermColor))
        terminalView.font = TerminalFontRegistry.monospacedFont(ofSize: fontSize)
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
        terminalView.focusRequested = false
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
        focusTask = nil
        guard let window = view.window else {
            view.focusRequested = true
            return
        }
        window.makeFirstResponder(view)
    }

    var terminalView: EdithTerminalView {
        if let swiftTermView { return swiftTermView }
        let view = EdithTerminalView.make()
        for (code, handler) in oscHandlers { Self.install(handler, code: code, on: view) }
        swiftTermView = view
        return view
    }

    func registerOSCHandler(code: Int, handler: @escaping @MainActor (String) -> Void) {
        oscHandlers[code] = handler
        if let swiftTermView { Self.install(handler, code: code, on: swiftTermView) }
    }

    private static func install(
        _ handler: @escaping @MainActor (String) -> Void, code: Int, on view: EdithTerminalView
    ) {
        view.terminal.registerOscHandler(code: code) { bytes in
            guard let payload = String(bytes: bytes, encoding: .utf8) else { return }
            Task { @MainActor in handler(payload) }
        }
    }

    func insertText(_ text: String) {
        if ghosttyLaunch != nil {
            sendGhosttyInput(text)
        } else {
            terminalView.send(Array(text.utf8))
        }
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

private final class TerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private let onExit: (Int32?) -> Void
    private let onTitle: (String) -> Void
    private let onWorkingDirectory: (String?) -> Void

    init(
        onExit: @escaping (Int32?) -> Void, onTitle: @escaping (String) -> Void,
        onWorkingDirectory: @escaping (String?) -> Void
    ) {
        self.onExit = onExit
        self.onTitle = onTitle
        self.onWorkingDirectory = onWorkingDirectory
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onWorkingDirectory(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit(exitCode)
    }
}

