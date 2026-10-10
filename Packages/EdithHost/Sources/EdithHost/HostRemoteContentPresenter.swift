import AppKit
import EdithHostCore
import EdithExtensionUI
@preconcurrency import ExtensionFoundation
@preconcurrency import ExtensionKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HostRemoteContentPresenter: HostExtensionContentPresenting {
    private let manager: HostRemoteSessionManager
    private var controllers: [UUID: HostRemoteViewController] = [:]
    private var closing: [UUID: Task<Void, Never>] = [:]
    private var failedClosures = Set<UUID>()
    private(set) var cleanupFailed = false

    init(manager: HostRemoteSessionManager) {
        self.manager = manager
        manager.detach = { [weak self] id in self?.detach(extensionID: id) }
        manager.receive = { [weak self] id, event in
            guard let presentation = event.presentationID,
                let controller = self?.controllers[presentation],
                controller.request.extensionID == id
            else { return }
            controller.receive(event)
        }
    }

    func controller(for request: HostExtensionContentRequest) async throws -> NSViewController {
        let handle = try await manager.scene(for: request)
        guard !Task.isCancelled else {
            endPresentation(id: request.presentationID)
            throw CancellationError()
        }
        let remote = EXHostViewController()
        remote.configuration = EXHostViewController.Configuration(
            appExtension: handle.identity, sceneID: handle.sceneIdentifier)
        let terminalUI =
            request.extensionID == "terminal"
            ? HostTerminalInputClient(
                update: { [manager] event in
                    try await manager.terminalUI(
                        presentationID: request.presentationID, event: event)
                },
                status: { [manager] in
                    try await manager.terminalUIStatus(presentationID: request.presentationID)
                }) : nil
        let controller = HostRemoteViewController(
            request: request, remote: remote, terminalUI: terminalUI,
            connect: { connection, state, receive in
                try await handle.connect(
                    through: connection, compact: state.compact, visible: state.visible,
                    width: state.width, receive: receive)
            },
            update: { state in
                try await handle.update(
                    compact: state.compact, visible: state.visible, width: state.width)
            })
        controllers[request.presentationID] = controller
        return controller
    }

    func herdrReadyWindow(for presentationID: UUID) -> NSWindow? {
        guard closing[presentationID] == nil, let controller = controllers[presentationID],
            controller.request.extensionID == "herdr", controller.connected,
            controller.state.visible,
            controller.failure == nil, controller.isViewLoaded, !controller.detached,
            !controller.view.isHiddenOrHasHiddenAncestor
        else { return nil }
        return controller.view.window
    }

    func window(for presentationID: UUID) -> NSWindow? {
        guard closing[presentationID] == nil, let controller = controllers[presentationID],
            controller.isViewLoaded, !controller.detached
        else {
            return nil
        }
        return controller.view.window
    }

    func consumeTerminalZoom(
        _ command: WindowKeyCommand, window: NSWindow?, fallback: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let window else { return false }
        for controller in controllers.values
        where controller.isViewLoaded && controller.view.window === window
            && closing[controller.request.presentationID] == nil
        {
            if controller.consumeTerminalZoom(command, fallback: fallback) { return true }
        }
        return false
    }

    func consumeTerminalTabKey(
        characters: String?, modifiers: NSEvent.ModifierFlags, window: NSWindow?
    ) -> Bool {
        guard let window else { return false }
        return controllers.values.contains { controller in
            controller.isViewLoaded && controller.view.window === window
                && closing[controller.request.presentationID] == nil
                && controller.consumeTerminalTabKey(characters: characters, modifiers: modifiers)
        }
    }

    func endPresentation(id: UUID) {
        guard closing[id] == nil else { return }
        closing[id] = Task { [weak self] in
            guard let self else { return }
            do {
                await controllers[id]?.prepareInputToClose()
                try await manager.prepareToClose(id: id)
                controllers.removeValue(forKey: id)?.detach()
                try await manager.endPresentation(id: id)
                failedClosures.remove(id)
            } catch {
                failedClosures.insert(id)
            }
            closing[id] = nil
            cleanupFailed = !failedClosures.isEmpty
        }
    }
    func endPresentationAndWait(id: UUID) async throws {
        endPresentation(id: id)
        await closing[id]?.value
        guard !failedClosures.contains(id) else { throw HostWorkerError.rejected }
    }

    func retryCleanup() {
        for id in failedClosures { endPresentation(id: id) }
    }
    private func detach(extensionID: String) {
        let ids = controllers.values.filter { $0.request.extensionID == extensionID }
            .map { $0.request.presentationID }
        for id in ids { controllers.removeValue(forKey: id)?.detach() }
    }
}

struct HostRemoteViewState: Equatable {
    var compact: Bool
    var visible: Bool
    var width: Double
    init(compact: Bool, visible: Bool, width: Double) {
        self.compact = compact
        self.visible = visible
        self.width = width.isFinite ? min(16_384, max(0, width)) : 0
    }
}

@MainActor
final class HostRemoteViewController: NSViewController, EXHostViewControllerDelegate {
    let request: HostExtensionContentRequest
    private var remote: EXHostViewController
    private let terminalUI: HostTerminalInputClient?
    private var terminalInput: HostTerminalInput?
    private let connect:
        @MainActor (
            NSXPCConnection, HostRemoteViewState, @escaping @MainActor (HostRemoteEvent) -> Void
        ) async throws -> Void
    private let update: @MainActor (HostRemoteViewState) async throws -> Void
    private var activation: Task<Void, Never>?
    private var updates: Task<Void, Never>?
    private var pending: HostRemoteViewState?
    private(set) var state = HostRemoteViewState(compact: false, visible: false, width: 0)
    private(set) var connected = false
    private(set) var detached = false
    private(set) var failure: String?
    private(set) var contentHeight: Double?
    private var revision = UUID()
    private var statusView: NSView?
    var changed: (() -> Void)?

    init(
        request: HostExtensionContentRequest, remote: EXHostViewController,
        terminalUI: HostTerminalInputClient? = nil,
        connect:
            @escaping @MainActor (
                NSXPCConnection, HostRemoteViewState, @escaping @MainActor (HostRemoteEvent) -> Void
            ) async throws -> Void,
        update: @escaping @MainActor (HostRemoteViewState) async throws -> Void
    ) {
        self.request = request
        self.remote = remote
        self.terminalUI = terminalUI
        self.connect = connect
        self.update = update
        super.init(nibName: nil, bundle: nil)
        remote.delegate = self
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let view = HostRemoteContainerView()
        view.contentHeight = contentHeight
        view.moved = { [weak self] in self?.terminalInput?.stateChanged() }
        self.view = view
        mountRemote()
        if let terminalUI, request.extensionID == "terminal" {
            terminalInput = HostTerminalInput(
                presentationID: request.presentationID, client: terminalUI,
                window: { [weak self] in self?.view.window },
                visible: { [weak self] in self?.state.visible == true },
                available: { [weak self] in self?.connected == true && self?.detached == false },
                ownsResponder: { [weak self] in self?.containsResponder(in: $0) == true })
        }
    }
    private func mountRemote() {
        addChild(remote)
        remote.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(remote.view)
        NSLayoutConstraint.activate([
            remote.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remote.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remote.view.topAnchor.constraint(equalTo: view.topAnchor),
            remote.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        remote.placeholderView = NSHostingView(
            rootView: Text("Opening extension").foregroundStyle(.secondary))
    }
    func apply(compact: Bool, visible: Bool, width: Double) {
        guard !detached else { return }
        let next = HostRemoteViewState(compact: compact, visible: visible, width: width)
        guard next != state else { return }
        state = next
        terminalInput?.stateChanged()
        guard connected else { return }
        pending = next
        drainUpdates()
    }
    func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
        guard viewController === remote, !detached, activation == nil, !connected else { return }
        do {
            try activate(through: viewController.makeXPCConnection())
        } catch { showFailure() }
    }
    func activate(through connection: NSXPCConnection) throws {
        guard !detached, activation == nil, !connected else { throw HostWorkerError.rejected }
        let token = revision
        activation = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { activation = nil } }
            do {
                try await connect(connection, state) { [weak self] event in self?.receive(event) }
                guard !Task.isCancelled, revision == token, !detached else { return }
                connected = true
                terminalInput?.stateChanged()
                pending = state
                drainUpdates()
            } catch {
                guard !Task.isCancelled, revision == token, !detached else { return }
                showFailure()
            }
        }
    }
    private func drainUpdates() {
        guard updates == nil, connected, !detached else { return }
        let token = revision
        updates = Task { [weak self] in
            guard let self else { return }
            defer { updates = nil }
            while let next = pending, revision == token, !detached, !Task.isCancelled {
                pending = nil
                do { try await update(next) } catch {
                    guard !Task.isCancelled, revision == token, !detached else { return }
                    showFailure(); return
                }
            }
        }
    }
    func receive(_ event: HostRemoteEvent) {
        guard !detached, event.presentationID == request.presentationID, event.kind == "height",
            let height = event.height, height.isFinite, (0...16_384).contains(height),
            !["main", "settings", "music.detail", "machines.window"].contains(request.location)
        else { return }
        contentHeight = height
        if isViewLoaded, let view = view as? HostRemoteContainerView {
            view.contentHeight = height
            view.invalidateIntrinsicContentSize()
        }
        changed?()
    }
    func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: Error?) {
        guard viewController === remote, !detached else { return }
        activation?.cancel(); updates?.cancel()
        terminalInput?.stop()
        connected = false
        showFailure()
    }
    private func showFailure() {
        guard !detached else { return }
        failure = "The extension interface could not connect."
        if let statusView { statusView.removeFromSuperview() }
        let notice = NSHostingView(
            rootView: ContentUnavailableView(
                "Extension unavailable", systemImage: "exclamationmark.triangle",
                description: Text(failure!)))
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            notice.topAnchor.constraint(equalTo: view.topAnchor),
            notice.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        statusView = notice
        changed?()
    }
    func consumeTerminalZoom(
        _ command: WindowKeyCommand, fallback: @escaping @MainActor () -> Void
    ) -> Bool {
        terminalInput?.consumeZoom(command, fallback: fallback) == true
    }

    func consumeTerminalTabKey(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        terminalInput?.consumeTabKey(characters: characters, modifiers: modifiers) == true
    }

    func waitUntilConnected(window: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !connected {
            try Task.checkCancellation()
            guard !detached, failure == nil, isViewLoaded, view.window === window,
                ContinuousClock.now < deadline
            else { throw HostWorkerError.rejected }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !detached, view.window === window else { throw HostWorkerError.rejected }
    }

    func prepareInputToClose() async { await terminalInput?.stopAndWait() }

    private func containsResponder(in window: NSWindow) -> Bool {
        guard isViewLoaded, view.window === window else { return false }
        var responder = window.firstResponder
        for _ in 0..<64 {
            guard let current = responder else { return false }
            if current === view || current === remote.view { return true }
            if let current = current as? NSView, current.isDescendant(of: remote.view) {
                return true
            }
            responder = current.nextResponder
        }
        return false
    }

    func detach() {
        guard !detached else { return }
        detached = true
        terminalInput?.stop()
        revision = UUID()
        activation?.cancel(); activation = nil
        updates?.cancel(); updates = nil
        pending = nil; connected = false
        changed = nil
        remote.delegate = nil
        remote.configuration = nil
        statusView?.removeFromSuperview(); statusView = nil
        if isViewLoaded {
            remote.view.removeFromSuperview()
            remote.removeFromParent()
        }
    }
}

private final class HostRemoteContainerView: NSView {
    var moved: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moved?()
    }
    var contentHeight: Double?
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight ?? NSView.noIntrinsicMetric)
    }
}
