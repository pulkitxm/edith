import AppKit
import EdithHostCore
import SwiftUI
import EdithExtensionUI

@MainActor
final class HostMachinesWindows {
    private let windows: HostSectionWindows
    private let origin: @MainActor (HostWorkerNavigationRequest) throws -> NSWindow
    private let load: @MainActor (HostExtensionContentRequest) async throws -> NSViewController
    private let ready: @MainActor (NSViewController, NSWindow) async throws -> Void
    private let release: @MainActor (UUID) async throws -> Void
    private let associate: @MainActor (NSWindow, NSWindow) throws -> UUID?
    private let removeAssociation: @MainActor (UUID) -> Void
    private var relationships: [UUID: UUID] = [:]
    private var presentations: [UUID: HostWorkerNavigationRequest] = [:]
    private var closures: [UUID: Task<Void, Never>] = [:]
    private var failed = Set<UUID>()
    private var stopping = false
    private var opening: [UUID: Task<Void, any Error>] = [:]

    init(
        windows: HostSectionWindows,
        origin: @escaping @MainActor (HostWorkerNavigationRequest) throws -> NSWindow,
        load: @escaping @MainActor (HostExtensionContentRequest) async throws -> NSViewController,
        ready: @escaping @MainActor (NSViewController, NSWindow) async throws -> Void,
        release: @escaping @MainActor (UUID) async throws -> Void,
        associate: @escaping @MainActor (NSWindow, NSWindow) throws -> UUID? = { _, _ in nil },
        removeAssociation: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.windows = windows; self.origin = origin; self.load = load
        self.ready = ready; self.release = release
        self.associate = associate; self.removeAssociation = removeAssociation
    }

    convenience init(
        manager: HostRemoteSessionManager, presenter: HostRemoteContentPresenter,
        navigation: HostWindowNavigation
    ) {
        self.init(
            windows: HostSectionWindows { _ in AnyView(EmptyView()) },
            origin: { [weak manager, weak presenter] request in
                guard let manager, let presenter else { throw HostWorkerError.rejected }
                try manager.validateNavigationOrigin(request)
                guard let id = request.presentationID, let window = presenter.window(for: id) else {
                    throw HostWorkerError.rejected
                }
                return window
            },
            load: { [weak presenter] request in
                guard let presenter else { throw HostWorkerError.rejected }
                return try await presenter.controller(for: request)
            },
            ready: { controller, window in
                guard let controller = controller as? HostRemoteViewController else {
                    throw HostWorkerError.rejected
                }
                try await controller.waitUntilConnected(window: window)
            },
            release: { [weak presenter] id in
                guard let presenter else { throw HostWorkerError.rejected }
                try await presenter.endPresentationAndWait(id: id)
            },
            associate: { [weak navigation] window, source in
                guard let navigation, let owner = navigation.owningWorkspace(for: source) else {
                    throw HostWorkerError.rejected
                }
                return try navigation.associate(window: window, with: owner)
            }, removeAssociation: { [weak navigation] in navigation?.removeAssociation($0) })
    }

    var pendingCount: Int { presentations.count }

    func open(_ request: HostWorkerNavigationRequest) async throws {
        guard !stopping, failed.isEmpty, request.extensionID == "machines",
            let target = request.machinesWindow,
            presentations.count < 8
        else { throw HostWorkerError.rejected }
        try target.validate()
        let owner = try origin(request)
        let id = UUID()
        presentations[id] = request
        let task = Task { [self] in try await mount(request, target: target, owner: owner, id: id) }
        opening[id] = task
        defer { opening[id] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func mount(
        _ request: HostWorkerNavigationRequest, target: HostMachinesWindowTarget, owner: NSWindow,
        id: UUID
    ) async throws {
        do {
            let controller = try await load(
                .init(
                    extensionID: "machines", location: "machines.window", section: "machines",
                    presentationID: id, machinesWindow: target))
            try Task.checkCancellation()
            guard !stopping, presentations[id] != nil, try origin(request) === owner else {
                throw HostWorkerError.rejected
            }
            let window = windows.openOwned(
                id: id, kind: target.kind,
                controller: NSHostingController(
                    rootView: HostOwnedRemoteContent(controller: controller))
            ) {
                [weak self] in self?.close(id)
            }
            if let token = try associate(window, owner) { relationships[id] = token }
            try await ready(controller, window)
            try Task.checkCancellation()
            guard !stopping, presentations[id] != nil, try origin(request) === owner,
                controller.isViewLoaded, controller.view.window === window
            else {
                throw HostWorkerError.rejected
            }
        } catch {
            windows.closeOwned(id: id)
            close(id)
            await closures[id]?.value
            throw error
        }
    }

    func stop() async throws {
        stopping = true
        defer { stopping = false }
        let pending = Array(opening.values)
        for task in pending { task.cancel() }
        for task in pending { _ = try? await task.value }
        windows.closeAll()
        for id in presentations.keys { close(id) }
        for task in Array(closures.values) { await task.value }
        guard presentations.isEmpty, failed.isEmpty else { throw HostWorkerError.rejected }
    }

    private func close(_ id: UUID) {
        guard presentations[id] != nil, closures[id] == nil else { return }
        if let token = relationships.removeValue(forKey: id) { removeAssociation(token) }
        closures[id] = Task { [weak self] in
            guard let self else { return }
            defer { closures[id] = nil }
            do {
                try await release(id)
                presentations[id] = nil; failed.remove(id)
            } catch { failed.insert(id) }
        }
    }
}

private struct HostOwnedRemoteContent: View {
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
