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
    private(set) var terminalLaunch: OwnedTerminalLaunch?
    private(set) var descriptor: OwnedTerminalDescriptor?
    private var engineSession: OwnedTerminalSession?
    private var client: OwnedTerminalClient?
    private var readTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var offset: UInt64 = 0
    private enum Event { case input(Data); case resize(UInt16, UInt16, UInt32, UInt32) }
    private var events: [Event] = []
    private var queuedBytes = 0
    private(set) var ghosttyView: GhosttyTerminalView?

    private var queuedGhosttyInput = ""
    private var managedOSC = QuinjetManagedOSC()
    private var oscHandlers: [Int: @MainActor (String) -> Void] = [:]
    func registerOSCHandler(code: Int, handler: @escaping @MainActor (String) -> Void) {
        guard code == QuinjetHostAction.oscCode else { return }
        oscHandlers[code] = handler
    }
    func consumeManagedOSC(_ bytes: Data) {
        for payload in managedOSC.append(bytes) { oscHandlers[QuinjetHostAction.oscCode]?(payload) }
    }
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
        let launch = OwnedTerminalLaunch(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory ?? "/", allowsLocalFileLinks: allowsLocalFileLinks,
            resetTerminalAfterInterrupt: resetTerminalAfterInterrupt)
        do {
            let session = try OwnedTerminalSession(launch: launch)
            engineSession = session
            terminalLaunch = launch
            bind(
                try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                    try await session.execute(operation, payload: payload)
                })
        } catch {
            started = false
            exitMessage = error.localizedDescription
        }
    }
    func insertText(_ text: String) { sendInput(text) }
    func applyTheme(
        _ palette: TerminalPalette, scale: Double = 1,
        fontSize: Double = 13
    ) {
        let theme = GhosttyTheme(
            palette: palette, fontSize: min(72, max(6, fontSize)) * scale)
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
        managedOSC = QuinjetManagedOSC()
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
        dropTransferError = nil
        generation += 1
        started = false
        exitMessage = nil
        currentTitle = nil
        currentWorkingDirectory = nil
        ghosttyView?.shutdown()
        ghosttyView = nil
        terminalLaunch = nil
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
        guard !text.isEmpty, descriptor != nil else { return }
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
                self.enqueue(.resize(columns, rows, width, height), bytes: 0)
            }, failure: { [weak self] in self?.failStream("The terminal input queue is full.") })
        let view = GhosttyTerminalView(
            externalIO: io, workingDirectory: descriptor?.directory,
            allowsLocalFileLinks: descriptor?.allowsLocalFileLinks ?? false,
            resetTerminalAfterInterrupt: descriptor?.resetTerminalAfterInterrupt ?? false,
            theme: theme)
        view.onClose = { [weak self, weak view] exitCode in
            QuinjetWorkOwnership.start { @MainActor in
                guard let self, let view, self.generation == viewGeneration,
                    self.ghosttyView === view
                else { return }
                self.finishSession(view, exitCode: exitCode)
            }
        }
        view.onTitleChange = { [weak self] title in
            QuinjetWorkOwnership.start { @MainActor in
                self?.setCurrentTitle(title, generation: viewGeneration)
            }
        }
        view.onWorkingDirectoryChange = { [weak self] directory in
            QuinjetWorkOwnership.start { @MainActor in
                self?.setCurrentWorkingDirectory(directory, generation: viewGeneration)
            }
        }
        view.onReady = { [weak self, weak view] in
            guard let self, let view, self.generation == viewGeneration else { return }
            self.flushQueuedInput(to: view)
            self.startReading(generation: viewGeneration)
        }
        ghosttyView = view
        flushQueuedInput(to: view)
        return view
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
        self.client?.stop()
        self.client = client
        descriptor = client.descriptor
        currentWorkingDirectory = client.descriptor.directory
        started = true
        exitMessage = nil
    }

    func executeTerminal(_ operation: String, payload: Data) async throws -> Data {
        guard let engineSession else { throw ExtensionPeerError.unavailable }
        let data = try await engineSession.execute(operation, payload: payload)
        if operation == "quinjet.terminal.read" {
            let output = try JSONDecoder().decode(OwnedTerminalPTY.Output.self, from: data)
            if output.nextOffset > offset {
                let count = min(output.bytes.count, Int(output.nextOffset - offset))
                consumeOutput(Data(output.bytes.suffix(count)))
                offset = output.nextOffset
            }
            if let exit = output.exitCode { exitMessage = Self.exitMessage(exit) }
        }
        return data
    }

    func stopRendering() {
        generation += 1
        readTask?.cancel()
        deliveryTask?.cancel()
        readTask = nil
        deliveryTask = nil
        events.removeAll()
        queuedBytes = 0
        client?.stop()
        client = nil
        ghosttyView?.shutdown()
        ghosttyView = nil
    }

    private func startReading(generation: Int) {
        guard readTask == nil, let client else { return }
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
        guard started, exitMessage == nil, client != nil else { return }
        guard events.count < 256, queuedBytes + bytes <= 262144 else {
            failStream("The terminal input queue is full."); return
        }
        events.append(event)
        queuedBytes += bytes
        guard deliveryTask == nil else { return }
        let generation = generation
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTask = nil }
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
        consumeManagedOSC(bytes)
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
