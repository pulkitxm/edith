import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import GhosttyTerminal
import Observation

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

    private(set) var transferringDrop = false
    private(set) var dropTransferError: String?
    private(set) var themeApplicationCount = 0
    private(set) var presentationGeneration = 0
    private var appliedTheme: GhosttyTheme?
    private var presentation: (Bool, Bool)?
    func start(
        executable: String, arguments: [String], environment: [String],
        currentDirectory: String? = nil, allowsLocalFileLinks: Bool = true,
        resetTerminalAfterInterrupt: Bool = false
    ) {
        guard !started else { return }
        queuedGhosttyInput = ""
        started = true
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = currentDirectory
        ghosttyLaunch = GhosttyLaunch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: currentDirectory, allowsLocalFileLinks: allowsLocalFileLinks,
            resetTerminalAfterInterrupt: resetTerminalAfterInterrupt)
    }
    func insertText(_ text: String) { sendInput(text) }
    func applyTheme(
        _ palette: TerminalPalette, scale: Double = 1,
        fontSize: Double = HerdrTerminalSettings.fontSizeDefault
    ) {
        let theme = GhosttyTheme(
            palette: palette, fontSize: HerdrTerminalSettings.clampedFontSize(fontSize) * scale)
        guard theme != appliedTheme else { return }
        appliedTheme = theme; themeApplicationCount += 1; ghosttyView?.apply(theme: theme)
    }
    func updatePresentation(active: Bool, wantsFocus: Bool) {
        let focus = active && wantsFocus
        guard presentation?.0 != active || presentation?.1 != focus else { return }
        presentation = (active, focus); presentationGeneration += 1
        ghosttyView?.setRenderingActive(active)
        if focus { ghosttyView?.requestFocus() } else { ghosttyView?.cancelFocusRequest() }
    }
    func deliverRemoteDrop(_ payload: TerminalDropPayload, upload: ([URL]) async throws -> [String])
        async
    {
        transferringDrop = true; dropTransferError = nil
        defer { transferringDrop = false; payload.removeTemporaryFiles() }
        do {
            let paths = try await upload(payload.files); try Task.checkCancellation();
            insertText(paths.map(ShellQuote.quote).joined(separator: " "))
        } catch { dropTransferError = error.localizedDescription }
    }

    func reset() {
        pendingUserClose = nil
        queuedGhosttyInput = ""
        appliedTheme = nil
        presentation = nil
        dropTransferError = nil
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
        pendingUserClose = PendingUserClose(
            viewID: ObjectIdentifier(ghosttyView), generation: generation,
            completion: completion)
        guard requestGhosttyClose(ghosttyView) else {
            pendingUserClose = nil
            stop()
            completion(true)
            return
        }
    }

    func sendInput(_ text: String) {
        guard !text.isEmpty, ghosttyLaunch != nil else { return }
        if let ghosttyView, queuedGhosttyInput.isEmpty, deliverGhosttyInput(ghosttyView, text) {
            return
        }
        queuedGhosttyInput += text
        if let ghosttyView { flushQueuedInput(to: ghosttyView) }
    }

    var hasQueuedInput: Bool { !queuedGhosttyInput.isEmpty }

    func retainedGhosttyView(launch: GhosttyLaunch, theme: GhosttyTheme) -> GhosttyTerminalView {
        if let ghosttyView {
            ghosttyView.apply(theme: theme)
            flushQueuedInput(to: ghosttyView)
            return ghosttyView
        }
        let view = GhosttyTerminalView(launch: launch, theme: theme)
        let viewGeneration = generation
        view.onClose = { [weak self, weak view] exitCode in
            HerdrWorkOwnership.start { @MainActor in
                guard let self, let view, self.generation == viewGeneration,
                    self.ghosttyView === view
                else { return }
                self.finishSession(view, exitCode: exitCode)
            }
        }
        view.onTitleChange = { [weak self] title in
            HerdrWorkOwnership.start { @MainActor in
                self?.setCurrentTitle(title, generation: viewGeneration)
            }
        }
        view.onWorkingDirectoryChange = { [weak self] directory in
            HerdrWorkOwnership.start { @MainActor in
                self?.setCurrentWorkingDirectory(directory, generation: viewGeneration)
            }
        }
        view.onReady = { [weak self, weak view] in
            guard let self, let view, self.generation == viewGeneration else { return }
            self.flushQueuedInput(to: view)
        }
        ghosttyView = view
        flushQueuedInput(to: view)
        return view
    }

    func finishSession(_ view: GhosttyTerminalView, exitCode: Int32?) {
        let closeCompletion = takeUserCloseCompletion(for: view)
        queuedGhosttyInput = ""
        view.shutdown()
        ghosttyView = nil
        ghosttyLaunch = nil
        generation += 1
        started = false
        currentTitle = nil
        currentWorkingDirectory = nil
        exitMessage = Self.exitMessage(exitCode)
        closeCompletion?(true)
    }

    static func exitMessage(_ exitCode: Int32?) -> String {
        exitCode == nil || exitCode == 0
            ? "Session ended." : "Session ended with status \(exitCode ?? 0)."
    }

    private func takeUserCloseCompletion(for view: GhosttyTerminalView)
        -> (@MainActor (Bool) -> Void)?
    {
        guard let request = pendingUserClose,
            request.viewID == ObjectIdentifier(view), request.generation == generation
        else { return nil }
        pendingUserClose = nil
        return request.completion
    }

    func setCurrentTitle(_ title: String?, generation: Int) {
        guard self.generation == generation else { return }
        currentTitle = title?.isEmpty == false ? title : nil
    }

    func setCurrentWorkingDirectory(_ directory: String?, generation: Int) {
        guard self.generation == generation else { return }
        currentWorkingDirectory = directory?.isEmpty == false ? directory : nil
    }

    private func flushQueuedInput(to view: GhosttyTerminalView) {
        guard ghosttyView === view, !queuedGhosttyInput.isEmpty else { return }
        let input = queuedGhosttyInput
        guard deliverGhosttyInput(view, input) else { return }
        queuedGhosttyInput = ""
    }
}
