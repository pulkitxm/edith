import AppKit
import GhosttyTerminal
import Observation
import Foundation

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
    private var dropTask: Task<Void, Never>?
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

    func start(_ launch: TerminalLaunch) {
        guard !started else { return }
        queuedGhosttyInput = ""
        started = true
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = launch.currentDirectory
        ghosttyLaunch = GhosttyLaunch(
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment, workingDirectory: launch.currentDirectory,
            allowsLocalFileLinks: true)
        if let command = launch.startupCommand { sendInput(command + "\n") }
    }

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

    func deliverRemoteDrop(
        _ payload: TerminalDropPayload, upload: @escaping ([URL]) async throws -> [String]
    ) async {
        guard !transferringDrop else { payload.removeTemporaryFiles(); return }
        transferringDrop = true
        dropTransferError = nil
        let task = Task { [weak self] in
            defer { payload.removeTemporaryFiles() }
            do {
                let paths = try await upload(payload.files)
                try Task.checkCancellation()
                self?.sendInput(paths.map(ShellQuote.quote).joined(separator: " "))
            } catch {
                if !Task.isCancelled { self?.dropTransferError = error.localizedDescription }
            }
        }
        dropTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        dropTask = nil
        transferringDrop = false
    }

    func reset() {
        dropTask?.cancel(); dropTask = nil
        pendingUserClose = nil
        queuedGhosttyInput = ""
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
            Task { @MainActor in
                guard let self, let view, self.generation == viewGeneration,
                    self.ghosttyView === view
                else { return }
                self.finishSession(view, exitCode: exitCode)
            }
        }
        view.onTitleChange = { [weak self] title in
            Task { @MainActor in self?.setCurrentTitle(title, generation: viewGeneration) }
        }
        view.onWorkingDirectoryChange = { [weak self] directory in
            Task { @MainActor in
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
