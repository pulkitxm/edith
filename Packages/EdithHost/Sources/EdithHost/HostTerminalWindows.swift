import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI

@MainActor
final class HostTerminalWindows {
    typealias SurfaceOwner =
        @MainActor (String, NSWindow) async throws ->
        (HostWorkerNavigationRequest, HostWorkspaceNavigationOwner)
    private let windows: HostSectionWindows
    private let owner:
        @MainActor (HostWorkerNavigationRequest) async throws -> HostWorkspaceNavigationOwner
    private let validateOrigin: @MainActor (HostWorkerNavigationRequest) throws -> Void
    private let load: @MainActor (HostExtensionContentRequest) async throws -> NSViewController
    private let ready: @MainActor (NSViewController, NSWindow) async throws -> Void
    private let healthy: @MainActor (NSViewController, NSWindow, UUID) throws -> Void
    private let release: @MainActor (UUID) async throws -> Void
    private let associate: @MainActor (NSWindow, NSWindow) throws -> UUID
    private let removeAssociation: @MainActor (UUID) -> Void
    private let presented: @MainActor (NSWindow) -> Bool
    private var entries: [UUID: Entry] = [:]
    private var opening: [UUID: Task<Void, any Error>] = [:]
    private var closures: [UUID: Task<Void, Never>] = [:]
    private var failed = Set<UUID>()
    private var stopping = false
    private var consumeKey: @MainActor (NSEvent) -> Bool = { _ in false }
    private var surfaceOwner: SurfaceOwner?
    nonisolated(unsafe) private var keyMonitor: Any?

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    init(
        windows: HostSectionWindows,
        owner:
            @escaping @MainActor (HostWorkerNavigationRequest) async throws ->
            HostWorkspaceNavigationOwner,
        validateOrigin: @escaping @MainActor (HostWorkerNavigationRequest) throws -> Void,
        load: @escaping @MainActor (HostExtensionContentRequest) async throws -> NSViewController,
        ready: @escaping @MainActor (NSViewController, NSWindow) async throws -> Void,
        release: @escaping @MainActor (UUID) async throws -> Void,
        associate: @escaping @MainActor (NSWindow, NSWindow) throws -> UUID,
        removeAssociation: @escaping @MainActor (UUID) -> Void,
        presented: @escaping @MainActor (NSWindow) -> Bool,
        healthy: @escaping @MainActor (NSViewController, NSWindow, UUID) throws -> Void = {
            _, _, _ in
        },
        surfaceOwner: SurfaceOwner? = nil
    ) {
        self.windows = windows; self.owner = owner; self.validateOrigin = validateOrigin
        self.load = load; self.ready = ready; self.release = release
        self.associate = associate; self.removeAssociation = removeAssociation
        self.presented = presented
        self.healthy = healthy
        self.surfaceOwner = surfaceOwner
    }

    convenience init(
        manager: HostRemoteSessionManager, presenter: HostRemoteContentPresenter,
        navigation: HostWindowNavigation, identity: HostIdentity
    ) {
        self.init(
            windows: HostSectionWindows { _ in AnyView(EmptyView()) },
            owner: { [weak navigation] request in
                guard let navigation else { throw HostWorkerError.rejected }
                return try await navigation.workspaceOwner(
                    extensionID: request.extensionID, version: request.version,
                    presentationID: request.presentationID, location: request.location)
            },
            validateOrigin: { [weak manager] request in
                guard let manager else { throw HostWorkerError.rejected }
                try manager.validateNavigationOrigin(request)
            },
            load: { [weak presenter] request in
                guard let presenter else { throw HostWorkerError.rejected }
                return try await presenter.controller(for: request)
            },
            ready: { controller, window in
                guard let remote = controller as? HostRemoteViewController else {
                    throw HostWorkerError.rejected
                }
                try await remote.waitUntilConnected(window: window)
                await Task.yield()
            },
            release: { [weak presenter] id in
                guard let presenter else { throw HostWorkerError.rejected }
                try await presenter.endPresentationAndWait(id: id)
            },
            associate: { [weak navigation] window, workspace in
                guard let navigation else { throw HostWorkerError.rejected }
                return try navigation.associate(window: window, with: workspace)
            },
            removeAssociation: { [weak navigation] in navigation?.removeAssociation($0) },
            presented: { $0.isVisible && !$0.isMiniaturized && $0.isKeyWindow && NSApp.isActive },
            healthy: { [weak presenter] controller, window, id in
                guard let presenter, let remote = controller as? HostRemoteViewController,
                    remote.request.extensionID == "terminal", remote.request.location == "main",
                    remote.request.presentationID == id,
                    presenter.owns(remote, presentationID: id)
                else { throw HostWorkerError.rejected }
                try presenter.validateConnected(remote, window: window)
            })
        consumeKey = { [weak presenter] event in
            presenter?.consumeTerminalTabKey(
                characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
                window: NSApp.keyWindow) == true
        }
        surfaceOwner = { [weak navigation] version, window in
            guard let navigation else { throw HostWorkerError.rejected }
            let owner = try await navigation.workspaceOwner(
                extensionID: "terminal", version: version, sourceWindow: window)
            return (
                HostWorkerNavigationRequest(
                    configuration: .init(
                        identity: identity, extensionID: "terminal", version: version)),
                owner
            )
        }
    }

    var pendingCount: Int { entries.count }

    func open(_ request: HostWorkerNavigationRequest) async throws {
        try admit(request)
        try validateOrigin(request)
        let workspace = try await owner(request)
        try await open(request, workspace: workspace) { [self] in try validateOrigin(request) }
    }

    func openSurface(
        version: String, window: NSWindow, validate: @escaping @MainActor () throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try validate()
        guard let surfaceOwner else { throw HostWorkerError.rejected }
        let (request, workspace) = try await surfaceOwner(version, window)
        try await open(request, workspace: workspace, validateRequest: validate)
    }

    private func open(
        _ request: HostWorkerNavigationRequest, workspace: HostWorkspaceNavigationOwner,
        validateRequest: @escaping @MainActor () throws -> Void
    ) async throws {
        try admit(request)
        try Task.checkCancellation()
        try validateRequest()
        try workspace.validate()
        if let pending = opening[workspace.token] {
            try await pending.value
            try Task.checkCancellation()
            try validateRequest()
            try workspace.validate()
        }
        if let entry = entries.values.first(where: {
            $0.owner.token == workspace.token && $0.version == request.version
                && closures[$0.id] == nil
        }), let window = entry.window, let controller = entry.controller {
            try entry.owner.validateRetained()
            guard windows.contains(window) else { throw HostWorkerError.rejected }
            windows.focusTerminalOwned(id: entry.id)
            try await ready(controller, window)
            try validate(
                request, workspace: workspace, entry: entry, window: window, controller: controller,
                validateRequest: validateRequest)
            return
        }
        guard entries.count < 8 else { throw HostWorkerError.rejected }
        let retained = HostWorkspaceNavigationOwner(
            token: workspace.token, window: workspace.window, validate: workspace.validateRetained)
        let entry = Entry(owner: retained, version: request.version)
        entries[entry.id] = entry
        let task = Task { [self] in
            try await mount(
                request, workspace: workspace, entry: entry, validateRequest: validateRequest)
        }
        opening[workspace.token] = task
        defer { opening[workspace.token] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func admit(_ request: HostWorkerNavigationRequest) throws {
        guard !stopping, failed.isEmpty, request.extensionID == "terminal",
            request.section == nil, request.relativePath == nil,
            request.machinesWindow == nil, request.herdrWindow == nil, request.folderChoice == nil
        else { throw HostWorkerError.rejected }
    }

    private func mount(
        _ request: HostWorkerNavigationRequest, workspace: HostWorkspaceNavigationOwner,
        entry: Entry, validateRequest: @escaping @MainActor () throws -> Void
    ) async throws {
        do {
            let controller = try await load(
                .init(extensionID: "terminal", location: "main", presentationID: entry.id))
            try Task.checkCancellation()
            try validateRequest()
            try workspace.validate()
            try entry.owner.validate()
            guard !stopping, entries[entry.id] === entry else { throw HostWorkerError.rejected }
            let window = windows.openTerminalOwned(
                id: entry.id,
                controller: NSHostingController(
                    rootView: HostTerminalRemoteContent(controller: controller)),
                didClose: { [weak self] in self?.close(entry.id) })
            entry.window = window; entry.controller = controller
            installKeys()
            entry.relationship = try associate(window, entry.owner.window)
            try await ready(controller, window)
            try validate(
                request, workspace: workspace, entry: entry, window: window,
                controller: controller, validateRequest: validateRequest)
        } catch {
            windows.closeTerminalOwned(id: entry.id)
            close(entry.id)
            await closures[entry.id]?.value
            throw error
        }
    }

    private func validate(
        _ request: HostWorkerNavigationRequest, workspace: HostWorkspaceNavigationOwner,
        entry: Entry, window: NSWindow, controller: NSViewController,
        validateRequest: @MainActor () throws -> Void
    ) throws {
        try Task.checkCancellation()
        try validateRequest()
        try workspace.validate()
        try entry.owner.validateRetained()
        guard !stopping, entries[entry.id] === entry, closures[entry.id] == nil,
            entry.version == request.version, entry.window === window,
            entry.controller === controller, entry.owner.token == workspace.token,
            windows.contains(window), controller.isViewLoaded, controller.view.window === window,
            presented(window)
        else { throw HostWorkerError.rejected }
        try healthy(controller, window, entry.id)
    }

    func stop() async throws {
        stopping = true
        defer { stopping = false }
        let pending = Array(opening.values)
        for task in pending { task.cancel() }
        for task in pending { _ = try? await task.value }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        windows.closeAll()
        for id in entries.keys { close(id) }
        for task in Array(closures.values) { await task.value }
        guard entries.isEmpty, failed.isEmpty else { throw HostWorkerError.rejected }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.windows.contains(NSApp.keyWindow) else { return false }
                return self.consumeKey(event)
            }
            return handled ? nil : event
        }
    }

    private func close(_ id: UUID) {
        guard let entry = entries[id], closures[id] == nil else { return }
        if let relationship = entry.relationship {
            removeAssociation(relationship); entry.relationship = nil
        }
        closures[id] = Task { [weak self] in
            guard let self else { return }
            defer { closures[id] = nil }
            do {
                try await release(id)
                entries[id] = nil; failed.remove(id)
            } catch { failed.insert(id) }
        }
    }

    private final class Entry {
        let id = UUID()
        let owner: HostWorkspaceNavigationOwner
        let version: String
        var window: NSWindow?
        var controller: NSViewController?
        var relationship: UUID?
        init(owner: HostWorkspaceNavigationOwner, version: String) {
            self.owner = owner; self.version = version
        }
    }
}

private struct HostTerminalRemoteContent: View {
    let controller: NSViewController
    @Environment(\.windowVisible) private var visible
    var body: some View {
        GeometryReader { geometry in
            HostEmbeddedController(
                controller: controller, compact: geometry.size.width < UIScale.pt(720),
                visible: visible)
        }
        .tracksWindowVisibility()
    }
}
