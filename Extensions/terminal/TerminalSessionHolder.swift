import AppKit
import GhosttyTerminal
import Observation

@MainActor @Observable final class TerminalSessionHolder {
    private enum Event {
        case input(Data)
        case resize(UInt16, UInt16, UInt16, UInt16)
        case presentation(String, String)
        case drop(TerminalDropPayload)
        case resolveLink(String, Bool)
        case openLink(UUID)
    }

    private(set) var session: TerminalEngine.Session
    private(set) var ghosttyView: GhosttyTerminalView?
    private(set) var exitMessage: String?
    private(set) var currentTitle: String?
    private(set) var currentWorkingDirectory: String?
    private(set) var error: String?
    private(set) var actionError: String?
    private var drops = 0
    private var stopped = false
    private var readTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var events: [Event] = []
    private var queuedBytes = 0
    private var offset: UInt64 = 0
    private let client: TerminalRemoteClient
    private let onClose: @MainActor () -> Void
    private let onPaneAction: @MainActor (GhosttyPaneAction) -> Void
    private var hostWindowState: (active: Bool, key: Bool)?
    var fontSize = TerminalSettings.fontSizeDefault
    var generation: UUID { session.generation }
    var started: Bool { !stopped && error == nil }

    init(
        session: TerminalEngine.Session, client: TerminalRemoteClient,
        onClose: @escaping @MainActor () -> Void,
        onPaneAction: @escaping @MainActor (GhosttyPaneAction) -> Void = { _ in }
    ) {
        self.session = session
        self.client = client
        self.onClose = onClose
        self.onPaneAction = onPaneAction
        currentTitle = session.title
        currentWorkingDirectory = session.directory
    }

    func update(_ session: TerminalEngine.Session) {
        guard !stopped, self.session.generation == session.generation else { return }
        self.session = session
        if let failure = session.error { fail(failure) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        readTask?.cancel()
        readTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        events.removeAll()
        queuedBytes = 0
        ghosttyView?.shutdown()
        ghosttyView = nil
    }

    func requestUserClose(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard !stopped else { completion(false); return }
        guard let view = ghosttyView, view.requestClose() else { completion(true); return }
        closeCompletion = completion
    }

    private var closeCompletion: (@MainActor (Bool) -> Void)?

    func retainedGhosttyView(theme: GhosttyTheme) -> GhosttyTerminalView {
        if let ghosttyView { ghosttyView.apply(theme: theme); return ghosttyView }
        let generation = session.generation
        let io = GhosttyExternalIO(
            write: { [weak self] bytes in
                guard let self, self.generation == generation else { return }
                self.enqueue(.input(bytes), bytes: bytes.count)
            },
            resize: { [weak self] columns, rows, width, height in
                guard let self, self.generation == generation else { return }
                self.enqueue(
                    .resize(columns, rows, UInt16(clamping: width), UInt16(clamping: height)),
                    bytes: 0)
            }, failure: { [weak self] in self?.fail("The terminal input queue is full.") })
        let view = GhosttyTerminalView(
            externalIO: io, workingDirectory: session.directory, theme: theme)
        ghosttyView = view
        if let hostWindowState {
            view.setHostWindowState(active: hostWindowState.active, key: hostWindowState.key)
        }
        view.onPaneAction = { [weak self] action in
            guard let self, !self.stopped, self.generation == generation else { return }
            self.onPaneAction(action)
        }
        view.onDropFiles = { [weak self] payload in
            guard let self, !self.stopped, self.generation == generation, self.drops == 0,
                self.exitMessage == nil
            else {
                return false
            }
            self.drops += 1
            self.enqueue(.drop(payload), bytes: 0)
            return true
        }
        view.onOpenTarget = { [weak self] value, untrusted in
            guard let self, !self.stopped, self.generation == generation else { return false }
            self.enqueue(.resolveLink(value, untrusted), bytes: 0)
            return true
        }
        view.onClose = { [weak self] _ in
            guard let self, !self.stopped, self.generation == generation else { return }
            let completion = self.closeCompletion
            self.closeCompletion = nil
            if let completion { completion(true) } else { self.onClose() }
        }
        view.onTitleChange = { [weak self] title in
            guard let self, !self.stopped, self.generation == generation else { return }
            self.currentTitle = TerminalWorker.bounded(title, bytes: 512)
            self.enqueuePresentation()
        }
        view.onWorkingDirectoryChange = { [weak self] directory in
            guard let self, !self.stopped, self.generation == generation else { return }
            self.currentWorkingDirectory = TerminalWorker.bounded(directory, bytes: 4_096)
            self.enqueuePresentation()
        }
        view.onReady = { [weak self] in self?.startReading(generation: generation) }
        return view
    }

    func setHostWindowState(active: Bool, key: Bool) {
        hostWindowState = (active, key)
        ghosttyView?.setHostWindowState(active: active, key: key)
    }

    private func startReading(generation: UUID) {
        guard readTask == nil, !stopped else { return }
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped, self.generation == generation else { return }
                do {
                    let output = try await self.client.read(self.session, after: self.offset)
                    guard !Task.isCancelled, !self.stopped, self.generation == generation,
                        let view = self.ghosttyView
                    else { return }
                    guard view.setTermios(canonical: output.canonical, echo: output.echo),
                        output.bytes.isEmpty || view.receiveOutput(output.bytes)
                    else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    self.offset = output.nextOffset
                    if let exitCode = output.exitCode {
                        _ = view.processExited(exitCode)
                        self.exitMessage = Self.exitMessage(exitCode)
                        return
                    }
                } catch is CancellationError { return } catch {
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.fail("The owned terminal stream is unavailable. Restart to reconnect.")
                    return
                }
            }
        }
    }

    private func enqueuePresentation() {
        enqueue(
            .presentation(
                currentTitle ?? session.title, currentWorkingDirectory ?? session.directory),
            bytes: 0)
    }

    private func enqueue(_ event: Event, bytes: Int) {
        guard !stopped else { return }
        if exitMessage != nil {
            switch event {
            case .resolveLink, .openLink, .presentation: break;
            default: return
            }
        }
        guard events.count < 256, queuedBytes + bytes <= 262_144 else {
            fail("The terminal input queue is full.")
            return
        }
        events.append(event)
        queuedBytes += bytes
        guard deliveryTask == nil else { return }
        let generation = generation
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTask = nil }
            while !Task.isCancelled, !self.stopped, self.generation == generation,
                !self.events.isEmpty
            {
                let event = self.events.removeFirst()
                do {
                    switch event {
                    case let .input(data):
                        self.queuedBytes -= data.count
                        try await self.client.input(data, to: self.session)
                    case let .resize(columns, rows, width, height):
                        try await self.client.resize(
                            self.session, columns: columns, rows: rows, widthPixels: width,
                            heightPixels: height)
                    case let .drop(payload):
                        defer { self.drops -= 1 }
                        do {
                            try await self.client.importDrop(payload, to: self.session);
                            self.actionError = nil
                        } catch { self.actionError = "The dropped content could not be imported." }
                    case let .resolveLink(value, untrusted):
                        do {
                            let reply = try await self.client.resolveLink(
                                value, untrusted: untrusted, session: self.session)
                            guard !self.stopped, self.generation == generation else { return }
                            self.ghosttyView?.presentLink(reply.resolution) { [weak self] in
                                guard let self, !self.stopped, self.generation == generation,
                                    let token = reply.token
                                else { return }
                                self.enqueue(.openLink(token), bytes: 0)
                            }
                        } catch { self.actionError = "The terminal link is unavailable." }
                    case let .openLink(token):
                        do {
                            try await self.client.openLink(token, session: self.session);
                            self.actionError = nil
                        } catch { self.actionError = "The terminal link could not be opened." }
                    case let .presentation(title, directory):
                        try await self.client.presentation(
                            self.session, title: title, directory: directory)
                    }
                } catch is CancellationError { return } catch {
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.fail("The owned terminal input is unavailable.")
                    return
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        error = message
        readTask?.cancel()
        deliveryTask?.cancel()
        events.removeAll()
        queuedBytes = 0
        ghosttyView?.shutdown()
        ghosttyView = nil
    }

    static func exitMessage(_ exitCode: Int32?) -> String {
        exitCode == nil || exitCode == 0
            ? "Session ended." : "Session ended with status \(exitCode ?? 0)."
    }
}
