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

    let id = UUID()
    private var closingTask: Task<Void, Never>?
    private var queuedExternalInput = Data()
    private var inputEvents = 0
    private(set) var generation = 0
    private(set) var started = false
    private(set) var exitMessage: String?
    private(set) var currentTitle: String?
    private(set) var currentWorkingDirectory: String?
    private(set) var hasTerminal = false
    private var externalIO: GhosttyExternalIO?
    private var engineRequest: MachineTerminalRequest?
    private var engineClient: MachineUIClient?
    private var engineTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputBytes = 0
    private(set) var ghosttyView: GhosttyTerminalView?

    private(set) var transferringDrop = false
    private(set) var dropTransferError: String?
    private var linkTask: Task<Void, Never>?
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

    func start(
        session: MachineSession, context: MachineTerminalContext? = nil,
        windowsShell: WindowsTerminalShell = .automatic, containerID: String? = nil
    ) {
        guard !started, let client = session.uiClient else { return }
        queuedGhosttyInput = ""
        started = true
        hasTerminal = true
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = context?.startingDirectory
        engineClient = client
        engineRequest = MachineTerminalRequest(
            operation: .open, machineID: session.id, tabID: id,
            directory: context?.startingDirectory, containerID: containerID,
            windowsShell: windowsShell)
        externalIO = GhosttyExternalIO(
            write: { [weak self] bytes in self?.enqueueInput(bytes) },
            resize: { [weak self] columns, rows, _, _ in
                self?.enqueueResize(columns: columns, rows: rows)
            },
            failure: { [weak self] in self?.fail("The terminal input queue is full.") })
    }

    private func startEngine() {
        guard engineTask == nil, let client = engineClient, let request = engineRequest else {
            return
        }
        let generation = generation
        let previous = closingTask
        engineTask = Task { [weak self] in
            var handle: UUID?
            do {
                await previous?.value
                try Task.checkCancellation()
                let opened = try await client.terminal(request)
                handle = opened.handle
                guard let handle, let self, generation == self.generation else {
                    throw CancellationError()
                }
                var owned = request
                owned.handle = handle
                self.engineRequest = owned
                let queued = queuedExternalInput + Data(queuedGhosttyInput.utf8)
                queuedExternalInput = Data(); queuedGhosttyInput = ""
                for offset in stride(from: 0, to: queued.count, by: 16_384) {
                    enqueueInput(queued.subdata(in: offset..<min(offset + 16_384, queued.count)))
                }
                var cursor: UInt64 = 0
                while !Task.isCancelled {
                    owned.operation = .read; owned.offset = cursor
                    let frame = try await client.terminal(owned)
                    guard generation == self.generation, let view = ghosttyView else {
                        throw CancellationError()
                    }
                    if !frame.bytes.isEmpty {
                        guard view.receiveOutput(frame.bytes) else {
                            throw MachineUIError.unavailable
                        }
                    }
                    cursor = frame.nextOffset
                    _ = view.setTermios(canonical: frame.canonical, echo: frame.echo)
                    if let code = frame.exitCode {
                        _ = view.processExited(code)
                        started = false
                        exitMessage = Self.exitMessage(code)
                        break
                    }
                    try await Task.sleep(for: .milliseconds(30))
                }
            } catch {
                if !Task.isCancelled, let self, generation == self.generation {
                    fail(error.localizedDescription)
                }
            }
            if let handle {
                var close = request; close.operation = .close; close.handle = handle
                let cleanup = Task { _ = try? await client.terminal(close) }
                await cleanup.value
            }
        }
    }

    private func enqueueInput(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let chunks = (bytes.count + 16_383) / 16_384
        guard inputBytes + queuedExternalInput.count + bytes.count <= 262_144,
            inputEvents + chunks <= 256
        else { fail("The terminal input queue is full."); return }
        for offset in stride(from: 0, to: bytes.count, by: 16_384) {
            enqueueInputChunk(bytes.subdata(in: offset..<min(offset + 16_384, bytes.count)))
        }
    }

    private func enqueueInputChunk(_ bytes: Data) {
        guard !bytes.isEmpty, bytes.count <= 16_384,
            inputBytes + queuedExternalInput.count + bytes.count <= 262_144, inputEvents < 256
        else { fail("The terminal input queue is full."); return }
        guard let client = engineClient, let request = engineRequest, request.handle != nil else {
            queuedExternalInput += bytes
            return
        }
        let previous = inputTask
        let generation = generation
        inputBytes += bytes.count
        inputEvents += 1
        inputTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { inputBytes -= bytes.count; inputEvents -= 1 }
            guard !Task.isCancelled, generation == self.generation else { return }
            var input = request; input.operation = .input; input.bytes = bytes
            do { _ = try await client.terminal(input) } catch {
                if !Task.isCancelled, generation == self.generation {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func enqueueResize(columns: UInt16, rows: UInt16) {
        guard let client = engineClient, var request = engineRequest else { return }
        request.columns = columns; request.rows = rows
        if request.handle == nil { engineRequest = request; return }
        guard inputEvents < 256 else { fail("The terminal input queue is full."); return }
        inputEvents += 1
        let previous = inputTask
        let generation = generation
        inputTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { inputEvents -= 1 }
            guard !Task.isCancelled, generation == self.generation else { return }
            request.operation = .resize
            do { _ = try await client.terminal(request) } catch {
                if !Task.isCancelled, generation == self.generation {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ message: String) {
        engineTask?.cancel()
        inputTask?.cancel()
        externalIO?.invalidate()
        started = false
        exitMessage = message
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
        engineTask?.cancel(); closingTask = engineTask; engineTask = nil
        inputTask?.cancel(); inputTask = nil
        linkTask?.cancel(); linkTask = nil
        externalIO?.invalidate(); externalIO = nil
        engineRequest = nil; engineClient = nil
        pendingUserClose = nil
        queuedGhosttyInput = ""
        queuedExternalInput = Data()
        generation += 1
        started = false
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = nil
        ghosttyView?.shutdown()
        ghosttyView = nil
        hasTerminal = false
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
        guard !text.isEmpty, hasTerminal else { return }
        if engineRequest?.handle != nil { enqueueInput(Data(text.utf8)); return }
        if let ghosttyView, queuedGhosttyInput.isEmpty, deliverGhosttyInput(ghosttyView, text) {
            return
        }
        guard
            queuedGhosttyInput.utf8.count + text.utf8.count + queuedExternalInput.count
                + inputBytes <= 262_144
        else { fail("The terminal input queue is full."); return }
        queuedGhosttyInput += text
        if let ghosttyView { flushQueuedInput(to: ghosttyView) }
    }

    var hasQueuedInput: Bool { !queuedGhosttyInput.isEmpty }

    func retainedGhosttyView(theme: GhosttyTheme) -> GhosttyTerminalView {
        if let ghosttyView {
            ghosttyView.apply(theme: theme)
            flushQueuedInput(to: ghosttyView)
            return ghosttyView
        }
        guard let externalIO else {
            preconditionFailure("The terminal must have an engine client.")
        }
        let view = GhosttyTerminalView(
            externalIO: externalIO, workingDirectory: currentWorkingDirectory,
            allowsLocalFileLinks: engineRequest?.machineID == Machine.localID, theme: theme)
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
        view.onOpenTarget = { [weak self, weak view] target, untrusted in
            guard let self, let view, generation == viewGeneration, ghosttyView === view,
                let client = engineClient, var request = engineRequest, request.handle != nil
            else { return false }
            linkTask?.cancel()
            request.operation = .resolveLink
            request.target = target; request.untrusted = untrusted
            request.directory = currentWorkingDirectory
            linkTask = Task { [weak self, weak view] in
                do {
                    let frame = try await client.terminal(request)
                    guard !Task.isCancelled, let self, let view, generation == viewGeneration,
                        ghosttyView === view, let encoded = frame.link, let id = frame.linkID
                    else { return }
                    let resolution = try JSONDecoder().decode(
                        TerminalLinkResolution.self, from: encoded)
                    view.presentLink(resolution) { [weak self, weak view] in
                        guard let self, let view, generation == viewGeneration,
                            ghosttyView === view
                        else { return }
                        var open = request; open.operation = .openLink; open.linkID = id
                        linkTask = Task { [weak self] in
                            do { _ = try await client.terminal(open) } catch {
                                if !Task.isCancelled {
                                    self?.dropTransferError = error.localizedDescription
                                }
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled { self?.dropTransferError = error.localizedDescription }
                }
            }
            return true
        }
        view.onReady = { [weak self, weak view] in
            guard let self, let view, self.generation == viewGeneration else { return }
            self.startEngine()
        }
        ghosttyView = view
        flushQueuedInput(to: view)
        return view
    }

    func finishSession(_ view: GhosttyTerminalView, exitCode: Int32?) {
        let closeCompletion = takeUserCloseCompletion(for: view)
        engineTask?.cancel(); closingTask = engineTask; engineTask = nil
        inputTask?.cancel(); inputTask = nil
        linkTask?.cancel(); linkTask = nil
        externalIO?.invalidate(); externalIO = nil
        queuedGhosttyInput = ""
        view.shutdown()
        ghosttyView = nil
        hasTerminal = false
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
        guard ghosttyView === view, engineRequest?.handle != nil, !queuedGhosttyInput.isEmpty else {
            return
        }
        let input = queuedGhosttyInput
        guard deliverGhosttyInput(view, input) else { return }
        queuedGhosttyInput = ""
    }
}
