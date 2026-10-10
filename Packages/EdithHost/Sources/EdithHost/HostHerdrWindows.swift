import AppKit
import EdithHostCore
import SwiftUI
import EdithExtensionUI

@MainActor
final class HostHerdrWindows {
    private let windows: HostSectionWindows
    private let origin: @MainActor (HostWorkerNavigationRequest) throws -> NSWindow
    private let load: @MainActor (HostExtensionContentRequest) async throws -> NSViewController
    private let ready: @MainActor (NSViewController, NSWindow) async throws -> Void
    private let release: @MainActor (UUID) async throws -> Void
    private let lease: @MainActor (HostWorkerNavigationRequest) throws -> HostHerdrWindowLease
    private var leases: [UUID: HostHerdrWindowLease] = [:]
    private var observers: [UUID: [NSObjectProtocol]] = [:]
    private var pendingFocus: [UUID: Bool] = [:]
    private var focusing: [UUID: Task<Void, Never>] = [:]
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
        lease: @escaping @MainActor (HostWorkerNavigationRequest) throws -> HostHerdrWindowLease,
        associate: @escaping @MainActor (NSWindow, NSWindow) throws -> UUID? = { _, _ in nil },
        removeAssociation: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.windows = windows; self.origin = origin; self.load = load
        self.ready = ready; self.release = release; self.lease = lease
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
            lease: { [weak manager] request in
                guard let manager else { throw HostWorkerError.rejected }
                return try manager.herdrWindowLease(request)
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
        guard !stopping, failed.isEmpty, request.extensionID == "herdr",
            let target = request.herdrWindow,
            presentations.count < 8
        else { throw HostWorkerError.rejected }
        try target.validate()
        let owner = try origin(request)
        let id = UUID()
        let retained = try lease(request)
        guard retained.target == target else { throw HostWorkerError.rejected }
        if let existing = leases.first(where: { $0.value.target.token == target.token }) {
            guard target.presented, existing.value.target.matches(target, presented: true),
                let original = presentations[existing.key],
                original.presentationID == request.presentationID,
                original.version == request.version,
                closures[existing.key] == nil, opening[existing.key] == nil
            else { throw HostWorkerError.rejected }
            try await retained.validate()
            guard try origin(request) === owner,
                windows.focusExisting("herdr.window." + existing.key.uuidString)
            else { throw HostWorkerError.rejected }
            return
        }
        leases[id] = retained
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
        _ request: HostWorkerNavigationRequest, target: HostHerdrWindowTarget, owner: NSWindow,
        id: UUID
    ) async throws {
        do {
            guard let retained = leases[id] else { throw HostWorkerError.rejected }
            try await retained.validate()
            let controller = try await load(
                .init(
                    extensionID: "herdr", location: target.location, section: "herdr",
                    presentationID: id, herdrWindow: target))
            try Task.checkCancellation()
            guard !stopping, presentations[id] != nil, try origin(request) === owner else {
                throw HostWorkerError.rejected
            }
            let window = windows.openHerdrOwned(
                id: id, target: target,
                controller: NSHostingController(
                    rootView: HostHerdrOwnedRemoteContent(controller: controller))
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
            try await retained.admit()
            guard !stopping, presentations[id] != nil, try origin(request) === owner else {
                throw HostWorkerError.rejected
            }
            observe(window, id: id)
        } catch {
            windows.closeHerdrOwned(id: id)
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

    private func observe(_ window: NSWindow, id: UUID) {
        observers[id] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] notification in
                let key = notification.name == NSWindow.didBecomeKeyNotification
                MainActor.assumeIsolated { self?.focus(id: id, key: key) }
            }
        }
    }

    private func focus(id: UUID, key: Bool) {
        guard !stopping, closures[id] == nil, let retained = leases[id] else { return }
        pendingFocus[id] = key
        guard focusing[id] == nil else { return }
        focusing[id] = Task { [weak self] in
            guard let self else { return }
            defer { focusing[id] = nil; pendingFocus[id] = nil }
            while !stopping, closures[id] == nil, let key = pendingFocus.removeValue(forKey: id) {
                do { try await retained.focus(key) } catch {
                    windows.closeHerdrOwned(id: id); close(id); return
                }
            }
        }
    }

    private func close(_ id: UUID) {
        guard presentations[id] != nil, closures[id] == nil else { return }
        for observer in observers.removeValue(forKey: id) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        if let token = relationships.removeValue(forKey: id) { removeAssociation(token) }
        closures[id] = Task { [weak self] in
            guard let self else { return }
            defer { closures[id] = nil }
            do {
                await focusing.removeValue(forKey: id)?.value
                try await release(id)
                guard let retained = leases[id] else { throw HostWorkerError.rejected }
                try await retained.close()
                leases[id] = nil
                presentations[id] = nil; failed.remove(id)
            } catch { failed.insert(id) }
        }
    }
}

private struct HostHerdrOwnedRemoteContent: View {
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
