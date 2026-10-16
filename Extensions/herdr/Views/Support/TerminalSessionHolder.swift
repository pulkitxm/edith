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

    private(set) var terminalColumns: UInt16 = 80
    private(set) var terminalRows: UInt16 = 24
    private(set) var generation = 0
    private(set) var started = false
    private(set) var exitMessage: String?
    private(set) var currentTitle: String?
    private(set) var currentWorkingDirectory: String?
    private(set) var terminalLaunch: OwnedTerminalLaunch?
    private(set) var descriptor: OwnedTerminalDescriptor?
    private var engineSession: OwnedTerminalSession?
    private var creationTask: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var retirementID: UUID?
    private var rendererReady = false
    private var client: OwnedTerminalClient?
    private var dropTask: Task<Void, Never>?
    private var linkResolveTask: Task<Void, Never>?
    private var linkOpenTask: Task<Void, Never>?
    private var linkRequest: UUID?
    private var readTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var offset: UInt64 = 0
    private enum Event { case input(Data); case resize(UInt16, UInt16, UInt32, UInt32) }
    private var events: [Event] = []
    private var queuedBytes = 0
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
    private var hostWindowState: (active: Bool, key: Bool, visible: Bool)?
    var nativePaneAction: (@MainActor (GhosttyPaneAction) -> Void)?
    func start(
        executable: String, arguments: [String], environment: [String],
        currentDirectory: String? = nil, allowsLocalFileLinks: Bool = true,
        resetTerminalAfterInterrupt: Bool = false
    ) {
        guard !started, creationTask == nil, !HerdrWorkOwnership.stopped else { return }
        queuedGhosttyInput = ""
        started = true
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = currentDirectory
        let launch = OwnedTerminalLaunch(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory ?? "/", allowsLocalFileLinks: allowsLocalFileLinks,
            resetTerminalAfterInterrupt: resetTerminalAfterInterrupt)
        terminalLaunch = launch
        let current = generation
        let previous = retirementTask
        creationTask = HerdrWorkOwnership.start { [self] in
            defer { if generation == current { creationTask = nil } }
            do {
                await previous?.value
                try Task.checkCancellation()
                guard generation == current, started else { throw CancellationError() }
                let session = try await OwnedTerminalSession(launch: launch)
                guard !Task.isCancelled, generation == current, started else {
                    await session.stopAndWait()
                    return
                }
                do {
                    let client = try OwnedTerminalClient(descriptor: session.descriptor) {
                        operation, payload in
                        try await session.execute(operation, payload: payload)
                    }
                    engineSession = session
                    bind(client)
                } catch {
                    await session.stopAndWait()
                    throw error
                }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                started = false
                exitMessage = error.localizedDescription
            }
        }
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
        ghosttyView?.setRenderingActive(active && (hostWindowState?.visible ?? true))
        if focus { ghosttyView?.requestFocus() } else { ghosttyView?.cancelFocusRequest() }
    }
    func setHostWindowState(active: Bool, key: Bool, visible: Bool) {
        hostWindowState = (active, key, visible)
        ghosttyView?.setHostWindowState(active: active, key: key && visible)
        ghosttyView?.setRenderingActive(visible && (presentation?.0 ?? true))
    }

    func handleDropFiles(_ payload: TerminalDropPayload, generation expected: Int? = nil) -> Bool {
        if let expected, expected != generation { payload.removeTemporaryFiles(); return true }
        guard retirementTask == nil, dropTask == nil else {
            dropTransferError = "A terminal file transfer is already in progress."
            payload.removeTemporaryFiles(); return true
        }
        guard let client else {
            dropTransferError = "The terminal is unavailable."
            payload.removeTemporaryFiles(); return true
        }
        let current = generation
        transferringDrop = true; dropTransferError = nil
        dropTask = Task { [weak self] in
            defer {
                payload.removeTemporaryFiles();
                if let self, self.generation == current {
                    self.transferringDrop = false; self.dropTask = nil
                }
            }
            do {
                var paths: [String] = []
                if client.descriptor.allowsLocalFileLinks {
                    for file in payload.files {
                        if payload.temporaryFiles.contains(file) {
                            paths += try await client.uploadFiles([file])
                        } else {
                            let result = try await client.fileRequest(
                                "paths",
                                .init(session: client.descriptor.handle, paths: [file.path]))
                            guard let values = result.paths, values == [file.path] else {
                                throw ExtensionPeerError.invalidRequest
                            }
                            paths += values
                        }
                    }
                } else {
                    paths = try await client.uploadFiles(payload.files)
                }
                if let media = payload.media {
                    guard !media.data.isEmpty, !media.fileExtension.isEmpty,
                        media.fileExtension.utf8.count <= 16,
                        media.fileExtension.utf8.allSatisfy({
                            (48...57).contains($0) || (65...90).contains($0)
                                || (97...122).contains($0)
                        })
                    else { throw ExtensionPeerError.invalidRequest }
                    paths += try await client.uploadBytes(
                        media.data, name: "drop." + media.fileExtension)
                }
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.insertText(paths.map(ShellQuote.quote).joined(separator: " "))
            } catch {
                if let self, self.generation == current, !Task.isCancelled {
                    self.dropTransferError = error.localizedDescription
                }
            }
        }
        return true
    }

    func reset() {
        retirePendingWork(closeSession: true)
        dropTask?.cancel(); dropTask = nil
        linkResolveTask?.cancel(); linkResolveTask = nil; linkOpenTask?.cancel();
        linkOpenTask = nil; linkRequest = nil
        transferringDrop = false
        readTask?.cancel()
        readTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        events.removeAll()
        queuedBytes = 0
        client?.stop()
        client = nil
        engineSession?.stop()
        engineSession = nil
        descriptor = nil
        offset = 0
        pendingUserClose = nil
        queuedGhosttyInput = ""
        appliedTheme = nil
        presentation = nil
        hostWindowState = nil
        nativePaneAction = nil
        dropTransferError = nil
        generation += 1
        started = false
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = nil
        rendererReady = false
        ghosttyView?.shutdown()
        ghosttyView = nil
        terminalLaunch = nil
    }

    func stop() {
        reset()
    }

    func waitForCreation() async throws {
        let current = generation
        let pending = creationTask
        await withTaskCancellationHandler {
            await pending?.value
        } onCancel: {
            pending?.cancel()
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        guard descriptor != nil else { throw ExtensionPeerError.unavailable }
    }

    func stopAndWait() async {
        stop()
        await retirementTask?.value
    }

    func stopRenderingAndWait() async {
        stopRendering()
        await retirementTask?.value
    }

    private func retirePendingWork(closeSession: Bool) {
        let pending = [
            creationTask, dropTask, linkResolveTask, linkOpenTask, readTask, deliveryTask,
        ]
        .compactMap { $0 }
        let client = client
        let session = closeSession ? engineSession : nil
        guard !pending.isEmpty || client != nil || session != nil else { return }
        for task in pending { task.cancel() }
        creationTask = nil
        dropTask = nil
        linkResolveTask = nil
        linkOpenTask = nil
        readTask = nil
        deliveryTask = nil
        client?.stop()
        session?.stop()
        let previous = retirementTask
        let id = UUID()
        retirementID = id
        retirementTask = Task { [self] in
            await previous?.value
            for task in pending { await task.value }
            await client?.stopAndWait()
            await session?.stopAndWait()
            guard retirementID == id else { return }
            retirementTask = nil
            retirementID = nil
            if rendererReady { startReading(generation: generation) }
            deliverEvents()
            if let ghosttyView { flushQueuedInput(to: ghosttyView) }
        }
        if let retirementTask { HerdrWorkOwnership.retain(retirementTask) }
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
        guard !text.isEmpty, started, descriptor != nil || creationTask != nil else { return }
        if let ghosttyView, queuedGhosttyInput.isEmpty, deliverGhosttyInput(ghosttyView, text) {
            return
        }
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
        let viewGeneration = generation
        let io = GhosttyExternalIO(
            write: { [weak self] bytes in
                guard let self, self.generation == viewGeneration else { return }
                self.enqueue(.input(bytes), bytes: bytes.count)
            },
            resize: { [weak self] columns, rows, width, height in
                guard let self, self.generation == viewGeneration else { return }
                self.terminalColumns = columns; self.terminalRows = rows
                self.enqueue(.resize(columns, rows, width, height), bytes: 0)
            }, failure: { [weak self] in self?.failStream("The terminal input queue is full.") })
        let view = GhosttyTerminalView(
            externalIO: io,
            workingDirectory: descriptor?.directory ?? terminalLaunch?.currentDirectory,
            allowsLocalFileLinks: descriptor?.allowsLocalFileLinks
                ?? terminalLaunch?.allowsLocalFileLinks ?? false,
            resetTerminalAfterInterrupt: descriptor?.resetTerminalAfterInterrupt
                ?? terminalLaunch?.resetTerminalAfterInterrupt ?? false,
            theme: theme)
        if let hostWindowState {
            view.setHostWindowState(
                active: hostWindowState.active, key: hostWindowState.key && hostWindowState.visible)
            view.setRenderingActive(hostWindowState.visible && (presentation?.0 ?? true))
        }
        view.onPaneAction = { [weak self, weak view] action in
            guard let self, let view, self.generation == viewGeneration, self.ghosttyView === view
            else { return }
            self.nativePaneAction?(action)
        }
        view.onOpenTarget = { [weak self, weak view] value, untrusted in
            guard let self, let view, self.generation == viewGeneration else { return false }
            return self.openTarget(value, untrusted: untrusted, view: view)
        }
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
            self.rendererReady = true
            self.flushQueuedInput(to: view)
            self.startReading(generation: viewGeneration)
        }
        ghosttyView = view
        flushQueuedInput(to: view)
        return view
    }

    private func openTarget(_ value: String, untrusted: Bool, view: GhosttyTerminalView) -> Bool {
        guard retirementTask == nil, let client, linkResolveTask == nil, linkOpenTask == nil
        else { return false }
        let current = generation
        let request = UUID()
        linkRequest = request
        linkResolveTask = Task { [weak self, weak view] in
            defer { if self?.linkRequest == request { self?.linkResolveTask = nil } }
            do {
                let reply = try await client.resolveLink(value, untrusted: untrusted)
                try Task.checkCancellation()
                guard let self, let view, self.generation == current, self.linkRequest == request,
                    self.ghosttyView === view
                else { return }
                view.presentLink(reply.resolution) { [weak self, weak view] in
                    guard let self, let view, let token = reply.token,
                        self.generation == current, self.linkRequest == request,
                        self.ghosttyView === view
                    else { return }
                    self.linkOpenTask = Task { [weak self] in
                        defer { if self?.linkRequest == request { self?.linkOpenTask = nil } }
                        do { try await client.openLink(token) } catch {
                            if self?.generation == current {
                                self?.dropTransferError = error.localizedDescription
                            }
                        }
                    }
                }
            } catch {
                if self?.generation == current, !Task.isCancelled {
                    self?.dropTransferError = error.localizedDescription
                }
            }
        }
        return true
    }

    func finishSession(_ view: GhosttyTerminalView, exitCode: Int32?) {
        guard ghosttyView === view else { return }
        let completion = takeUserCloseCompletion(for: view)
        if let completion { reset(); completion(true); return }
        queuedGhosttyInput = ""
        _ = view.processExited(exitCode ?? 0)
        exitMessage = Self.exitMessage(exitCode)
    }

    func bind(_ client: OwnedTerminalClient) {
        if self.client != nil { retirePendingWork(closeSession: false) }
        self.client = client
        descriptor = client.descriptor
        currentWorkingDirectory = client.descriptor.directory
        started = true
        exitMessage = nil
        if rendererReady { startReading(generation: generation) }
        deliverEvents()
        if let ghosttyView { flushQueuedInput(to: ghosttyView) }
    }

    func executeTerminal(_ operation: String, payload: Data) async throws -> Data {
        guard let engineSession else { throw ExtensionPeerError.unavailable }
        return try await engineSession.execute(operation, payload: payload)
    }

    func stopRendering() {
        retirePendingWork(closeSession: false)
        dropTask?.cancel(); dropTask = nil
        linkResolveTask?.cancel(); linkResolveTask = nil; linkOpenTask?.cancel();
        linkOpenTask = nil; linkRequest = nil
        transferringDrop = false
        generation += 1
        readTask?.cancel()
        deliveryTask?.cancel()
        readTask = nil
        deliveryTask = nil
        events.removeAll()
        queuedBytes = 0
        client?.stop()
        client = nil
        rendererReady = false
        ghosttyView?.shutdown()
        ghosttyView = nil
    }

    private func startReading(generation: Int) {
        guard retirementTask == nil, readTask == nil, let client else { return }
        readTask = Task { [weak self] in
            var cursor: UInt64 = 0
            while !Task.isCancelled {
                do {
                    let output = try await client.read(after: cursor)
                    guard let self, !Task.isCancelled, self.generation == generation,
                        let view = self.ghosttyView
                    else { return }
                    guard view.setTermios(canonical: output.canonical, echo: output.echo),
                        output.bytes.isEmpty || view.receiveOutput(output.bytes)
                    else {
                        throw ExtensionPeerError.unavailable
                    }
                    self.consumeOutput(output.bytes)
                    cursor = output.nextOffset
                    self.offset = cursor
                    if let exit = output.exitCode {
                        self.finishSession(view, exitCode: exit)
                        return
                    }
                } catch is CancellationError { return } catch {
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    self.failStream("The owned terminal stream is unavailable.")
                    return
                }
            }
        }
    }

    private func enqueue(_ event: Event, bytes: Int) {
        guard started, retirementTask == nil, exitMessage == nil,
            client != nil || creationTask != nil
        else { return }
        switch (events.last, event) {
        case (.resize, .resize):
            events[events.count - 1] = event
            deliverEvents()
            return
        case let (.input(queued), .input(data))
        where queued.count + data.count <= OwnedTerminalPTY.maximumInputBytes:
            events[events.count - 1] = .input(queued + data)
            queuedBytes += bytes
            deliverEvents()
            return
        default: break
        }
        guard events.count < 256, queuedBytes + bytes <= 262144 else {
            failStream("The terminal input queue is full."); return
        }
        events.append(event)
        queuedBytes += bytes
        deliverEvents()
    }

    private func deliverEvents() {
        guard retirementTask == nil, deliveryTask == nil, client != nil, !events.isEmpty else {
            return
        }
        let generation = generation
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.deliveryTask = nil } }
            while !Task.isCancelled, self.generation == generation, !self.events.isEmpty {
                guard let client = self.client else { return }
                let event = self.events.removeFirst()
                do {
                    switch event {
                    case .input(let data):
                        self.queuedBytes -= data.count
                        try await client.input(data)
                    case .resize(let columns, let rows, let width, let height):
                        try await client.resize(
                            columns: columns, rows: rows, pixelWidth: width, pixelHeight: height)
                    }
                } catch is CancellationError { return } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.failStream("The owned terminal input is unavailable."); return
                }
            }
        }
    }

    private func failStream(_ message: String) {
        stopRendering()
        exitMessage = message
        started = false
    }

    private func consumeOutput(_ bytes: Data) {
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
