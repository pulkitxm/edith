import AppKit
import Darwin
import EdithExtensionSupport
import EdithHostCore
import Foundation
import Observation

@MainActor
struct HostNotchWindowAssociation {
    let associate: @MainActor (NSWindow) throws -> UUID
    let remove: @MainActor (UUID) -> Void
}

@MainActor
struct HostNotchPointerMonitors {
    let start: @MainActor (@escaping @MainActor () -> Void) -> [Any]
    let remove: @MainActor (Any) -> Void

    static var native: Self {
        .init(
            start: { deliver in
                let mask: NSEvent.EventTypeMask = [
                    .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                ]
                var monitors: [Any] = []
                if let monitor = NSEvent.addGlobalMonitorForEvents(
                    matching: mask, handler: { _ in deliver() })
                {
                    monitors.append(monitor)
                }
                if let monitor = NSEvent.addLocalMonitorForEvents(
                    matching: mask,
                    handler: { event in
                        deliver(); return event
                    })
                {
                    monitors.append(monitor)
                }
                return monitors
            }, remove: { NSEvent.removeMonitor($0) })
    }
}

@MainActor
final class HostNotchLifecycleAdapter {
    typealias Make = @MainActor (String) throws -> HostNotchPanelCoordinator
    private let environment: HostNotchPanelCoordinator.Environment
    private let screens: @MainActor () -> [HostNotchPanelScreen]
    private let make: Make
    private let monitors: HostNotchPointerMonitors
    private var coordinator: HostNotchPanelCoordinator?
    private var version: String?
    private var attachedScreens: [HostNotchPanelScreen] = []
    private var transition: Task<Void, any Error>?
    private var updating: Task<Void, Never>?
    private var pending = false
    private var installed = false
    private var stopped = false
    private var screenObserver: NSObjectProtocol?
    private var eventMonitors: [Any] = []
    private(set) var failure: String?

    init(
        environment: @escaping HostNotchPanelCoordinator.Environment,
        screens: @escaping @MainActor () -> [HostNotchPanelScreen],
        monitors: HostNotchPointerMonitors = .native, make: @escaping Make
    ) {
        self.environment = environment; self.screens = screens; self.make = make
        self.monitors = monitors
    }

    convenience init(
        marketplace: HostMarketplace, manager: HostRemoteSessionManager,
        association: HostNotchWindowAssociation,
        compactNavigate: @escaping HostNotchCompactCardModel.Navigate
    ) {
        weak var adapter: HostNotchLifecycleAdapter?
        let environment: HostNotchPanelCoordinator.Environment = {
            let versions = marketplace.sessions.versions.filter {
                marketplace.sessions.activeIDs.contains($0.key)
                    && marketplace.installed[$0.key]?.version == $0.value
                    && !marketplace.pendingRemovalIDs.contains($0.key)
            }
            let layout = marketplace.surfaceLayouts.notch
            let hidden = Set(
                SurfaceWidget.library(extensionIDs: marketplace.entries.map(\.id)).filter {
                    marketplace.surfaces.privacy.hides($0)
                })
            return .init(
                activeVersions: versions, layout: layout, hiddenWidgets: hidden,
                reservedProviderScenes: manager.presentationCounts(
                    excluding: adapter?.coordinator?.presentationIDs ?? []))
        }
        self.init(environment: environment, screens: Self.connectedScreens) { version in
            let peer = try HostNotchEnginePeer(marketplace: marketplace, version: version)
            return HostNotchPanelCoordinator(
                invoke: peer.invoke, environment: environment, association: association,
                create: { request in
                    if request.section == "surface.card" {
                        guard let coordinator = adapter?.coordinator,
                            let origin = coordinator.compactOrigin(for: request)
                        else { throw HostNotchPanelError.staleState }
                        let model = HostNotchCompactCardModel(
                            origin: origin,
                            requests: marketplace.surfaces.requests,
                            admission: { [weak coordinator] in coordinator?.compactVersions($0) },
                            navigate: compactNavigate)
                        return HostNotchCompactController.lease(
                            request: request, model: model, layout: environment().layout)
                    }
                    return try await HostNotchSceneLease.remote(manager: manager, request: request)
                })
        }
        adapter = self
        let previous = marketplace.sessions.willDisable
        marketplace.sessions.willDisable = { [weak self] id in
            if id == "notchShelf" {
                guard let self else { throw HostNotchPanelError.staleState }
                try await self.performTransition(cancelWithCaller: false) {
                    try await self.retireCurrent()
                }
            } else {
                self?.coordinator?.synchronize()
            }
            try await previous(id)
        }
    }

    var pendingCleanupCount: Int { coordinator?.pendingCleanupCount ?? 0 }
    var panelCount: Int { coordinator?.panelCount ?? 0 }

    func window(for presentationID: UUID) -> NSWindow? {
        guard !stopped, environment().activeVersions["notchShelf"] == version else { return nil }
        return coordinator?.window(for: presentationID)
    }

    func install() {
        guard !installed, !stopped else { return }
        installed = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        observe()
        scheduleRefresh()
    }

    private func synchronizeMonitors() {
        guard installed, !stopped, environment().activeVersions["notchShelf"] == version,
            (coordinator?.activePanelCount ?? 0) > 0
        else { removeMonitors(); return }
        guard eventMonitors.isEmpty else { return }
        eventMonitors = monitors.start { [weak self] in
            guard let self, !stopped else { return }
            for screen in attachedScreens {
                coordinator?.pointer(
                    displayID: screen.display.id, globalPoint: NSEvent.mouseLocation,
                    buttons: UInt32(NSEvent.pressedMouseButtons & 31),
                    option: NSEvent.modifierFlags.contains(.option), draggingFiles: false)
            }
        }
    }

    private func removeMonitors() {
        for monitor in eventMonitors { monitors.remove(monitor) }
        eventMonitors = []
    }

    func refresh() async throws {
        try await performTransition { [self] in try await refreshOwned() }
    }

    private func refreshOwned() async throws {
        try Task.checkCancellation()
        guard !stopped else { return }
        defer { synchronizeMonitors() }
        let current = environment()
        let nextScreens = screens()
        let nextVersion = current.activeVersions["notchShelf"]
        let sameScreens = nextScreens.map { ScreenKey($0) } == attachedScreens.map { ScreenKey($0) }
        if coordinator != nil, nextVersion != version || !sameScreens {
            try await retireCurrent()
        }
        guard let nextVersion else { return }
        if let coordinator { coordinator.synchronize(); return }
        let next = try make(nextVersion)
        coordinator = next; version = nextVersion; attachedScreens = nextScreens
        next.didChangePanels = { [weak self] in self?.synchronizeMonitors() }
        do {
            try await next.start(version: nextVersion, screens: nextScreens)
            failure = nil
        } catch {
            if next.pendingCleanupCount == 0 {
                coordinator = nil; version = nil; attachedScreens = []
            }
            failure = "The Notch panel could not start. Retry its cleanup before enabling it again."
            throw error
        }
    }

    func owningWorkspaceChanged() async throws {
        guard !stopped else { return }
        try await performTransition { [self] in
            guard !stopped else { return }
            try await retireCurrent()
            try await refreshOwned()
        }
    }

    private func performTransition(
        cancelWithCaller: Bool = true,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        while let transition { _ = try? await transition.value }
        if cancelWithCaller { try Task.checkCancellation() }
        let task = Task { [self] in
            defer { transition = nil }
            try await operation()
        }
        transition = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if cancelWithCaller { task.cancel() }
        }
    }

    func stop() async throws {
        stopped = true
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeMonitors()
        updating?.cancel()
        if let updating { await updating.value }
        updating = nil
        try await performTransition(cancelWithCaller: false) { [self] in try await retireCurrent() }
    }

    private func retireCurrent() async throws {
        removeMonitors()
        guard let coordinator else { return }
        do {
            try await coordinator.stop()
            self.coordinator = nil; version = nil; attachedScreens = []; failure = nil
        } catch {
            failure = "The Notch panel is still stopping. Retry cleanup."
            throw error
        }
    }

    private func scheduleRefresh() {
        guard !stopped else { return }
        pending = true
        guard updating == nil else { return }
        updating = Task { [weak self] in
            guard let self else { return }
            defer { updating = nil }
            while pending, !stopped, !Task.isCancelled {
                pending = false
                do { try await refresh() } catch { failure = "The Notch panel needs cleanup." }
            }
        }
    }

    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            _ = environment()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.observe(); self.scheduleRefresh()
            }
        }
    }

    static func connectedScreens() -> [HostNotchPanelScreen] {
        NSScreen.screens.compactMap { screen in
            guard
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? UInt32
            else {
                return nil
            }
            let left = screen.auxiliaryTopLeftArea?.width
            let right = screen.auxiliaryTopRightArea?.width
            let cutout = left.flatMap { left in right.map { screen.frame.width - left - $0 } }
            let collapsed =
                screen.safeAreaInsets.top > 0 && (cutout ?? 0) > 1
                ? CGSize(width: cutout!, height: screen.safeAreaInsets.top)
                : CGSize(width: 150, height: 28)
            return .init(
                display: .init(id: id, frame: screen.frame, collapsedSize: collapsed),
                isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    private struct ScreenKey: Equatable {
        let display: HostNotchDisplay
        let builtin: Bool
        init(_ screen: HostNotchPanelScreen) {
            display = screen.display; builtin = screen.isBuiltin
        }
    }
}

@MainActor
private final class HostNotchEnginePeer {
    private let marketplace: HostMarketplace
    private let version: String
    private let process: HostRemoteKernelIdentity
    private let endpoint: ExtensionPeerEndpoint
    private var attach: HostNotchPanelAttach?
    private var pending = 0

    init(marketplace: HostMarketplace, version: String) throws {
        self.marketplace = marketplace; self.version = version
        guard let pid = marketplace.sessions.processIdentifiers["notchShelf"] else {
            throw HostWorkerError.rejected
        }
        process = try .read(pid)
        endpoint = try .init(
            namespace: marketplace.identity.identifier, owner: "notchShelf",
            directory: marketplace.identity.root.appendingPathComponent("ExtensionState/Commands"))
        try validate(cleanup: false)
    }

    func invoke(_ operation: String, payload: Data, timeout: Double) async throws -> Data {
        let normal = Set([
            "notch.panel.wait", "notch.panel.pointer", "notch.panel.measure",
            "notch.panel.drop", "notch.panel.promise.prepare", "notch.panel.transfer.ack",
        ])
        let cleanup = Set([
            "notch.panel.detach", "notch.panel.scene.stop",
            "notch.panel.transfer.finish", "notch.panel.promise.finish",
        ])
        guard
            normal.contains(operation) || cleanup.contains(operation)
                || operation == "notch.panel.attach",
            payload.count <= HostNotchPanelState.maximumBytes,
            timeout.isFinite, (0.01...30).contains(timeout), pending < 8
        else {
            throw HostWorkerError.rejected
        }
        var recovery = false
        if operation == "notch.panel.attach" {
            let next = try JSONDecoder().decode(HostNotchPanelAttach.self, from: payload)
            guard next.version == version else { throw HostWorkerError.rejected }
            if let attach {
                guard attach == next else { throw HostWorkerError.rejected }
                recovery = true
            } else {
                try validate(cleanup: false)
                attach = next
            }
        }
        let allowCleanup = cleanup.contains(operation) || recovery
        try validate(cleanup: allowCleanup)
        pending += 1
        defer { pending -= 1 }
        let result = try await endpoint.invoke(operation, payload: payload, timeout: timeout)
        try validate(cleanup: allowCleanup)
        guard result.count <= HostNotchPanelState.maximumBytes else {
            throw HostWorkerError.invalidResponse
        }
        return result
    }

    private func validate(cleanup: Bool) throws {
        guard marketplace.installed["notchShelf"]?.version == version,
            marketplace.sessions.versions["notchShelf"] == version,
            marketplace.sessions.processIdentifiers["notchShelf"] == process.pid,
            process.isRunning,
            cleanup
                || (marketplace.sessions.activeIDs.contains("notchShelf")
                    && !marketplace.pendingRemovalIDs.contains("notchShelf"))
        else {
            throw HostWorkerError.rejected
        }
        let url = endpoint.directory.appendingPathComponent(endpoint.name + ".json")
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HostWorkerError.rejected }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG,
            (1...4096).contains(info.st_size), let data = try handle.read(upToCount: 4097),
            data.count <= 4096
        else {
            throw HostWorkerError.rejected
        }
        let record = try JSONDecoder().decode(Registration.self, from: data)
        guard record.logicalName == endpoint.name, record.process.pid == process.pid,
            record.process == ExtensionProcessIdentity.read(process.pid)
        else { throw HostWorkerError.rejected }
    }

    private struct Registration: Decodable {
        let logicalName: String
        let process: ExtensionProcessIdentity
    }
}
