import AppKit
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor
public final class HostRemoteSessionManager {
    public var detach: @MainActor (String) -> Void = { _ in }
    public var receive: @MainActor (String, HostRemoteEvent) -> Void = { _, _ in }
    private let marketplace: HostMarketplace
    private var presentations: [UUID: any HostScenePresentation] = [:]
    private var localSessions: [String: HostLocalSession] = [:]
    private var terminalClients: [UUID: HostTerminalSceneClient] = [:]
    private var admissions: [String: Set<UUID>] = [:]
    private var pendingCleanup: [UUID: String] = [:]
    private var verifiedIdentities: [String: (package: ExtensionPackage, identity: String)] = [:]
    public init(marketplace: HostMarketplace) {
        self.marketplace = marketplace
        marketplace.sessions.willDisable = { [weak self] id in
            try await self?.stop(extensionID: id)
        }
    }

    public func scene(for request: HostExtensionContentRequest) async throws
        -> HostLocalSceneHandle
    {
        let id = request.extensionID
        let token = UUID()
        admissions[id, default: []].insert(token)
        return try await withTaskCancellationHandler {
            do {
                let handle = try await prepareScene(for: request)
                finishAdmission(id: id, token: token)
                return handle
            } catch {
                finishAdmission(id: id, token: token)
                try? await stopUnused(extensionID: id)
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishAdmission(id: id, token: token)
            }
        }
    }

    private func prepareScene(for request: HostExtensionContentRequest) async throws
        -> HostLocalSceneHandle
    {
        try Task.checkCancellation()
        let configuration = try selectedConfiguration(for: request)
        let id = request.extensionID
        let engine =
            configuration.uiOnly
            ? nil
            : try HostRemoteEngineOwner(
                marketplace: marketplace, configuration: configuration)
        let session: HostLocalSession
        if let current = localSessions[id], current.configuration.package == configuration.package,
            current.configuration.uiOnly == configuration.uiOnly, current.isAvailable,
            current.engineIdentity == engine?.process
        {
            session = current
        } else {
            if let current = localSessions[id] {
                detach(id)
                current.stop()
            }
            session = try HostLocalSession(
                configuration: configuration, engine: engine, marketplace: marketplace)
            localSessions[id] = session
        }
        let handle = try session.reserve(request)
        presentations[request.presentationID] = handle
        return handle
    }

    public func validatePresented(_ request: HostExtensionContentRequest) throws {
        guard let handle = presentations[request.presentationID], handle.request == request else {
            throw HostWorkerError.rejected
        }
        try validateNavigationOrigin(
            HostWorkerNavigationRequest(
                configuration: handle.configuration.worker, presentationID: request.presentationID,
                location: request.location))
    }

    public func validateNavigationOrigin(_ request: HostWorkerNavigationRequest) throws {
        let id = request.extensionID
        guard marketplace.sessions.activeIDs.contains(id),
            marketplace.sessions.versions[id] == request.version,
            !marketplace.pendingRemovalIDs.contains(id)
        else { throw HostWorkerError.rejected }
        if let presentationID = request.presentationID {
            guard let handle = presentations[presentationID], handle.isPresented,
                handle.request.extensionID == id,
                request.machinesWindow != nil || request.herdrWindow != nil
                    || handle.request.location == request.location,
                pendingCleanup[presentationID] == nil, handle.processIdentity?.isRunning == true
            else { throw HostWorkerError.rejected }
            let selected = try selectedConfiguration(for: handle.request)
            guard !selected.uiOnly, selected.package == handle.configuration.package,
                let pid = marketplace.sessions.processIdentifiers[id],
                handle.engineIdentity == (try HostRemoteKernelIdentity.read(pid))
            else { throw HostWorkerError.rejected }
        } else if request.location != nil || request.machinesWindow != nil
            || request.herdrWindow != nil
        {
            throw HostWorkerError.rejected
        }
    }

    public func folderChoiceOrigin(
        _ request: HostWorkerNavigationRequest, windowRegistration: UUID
    ) throws -> HostFolderChoiceOrigin {
        try validateNavigationOrigin(request)
        guard let id = request.presentationID, let handle = presentations[id],
            handle.request.location == "settings", handle.request.section == "agentActivity",
            let engine = handle.engineIdentity, let renderer = handle.processIdentity
        else { throw HostWorkerError.rejected }
        try request.validate(configuration: handle.configuration.worker)
        let origin = HostFolderChoiceOrigin(
            extensionID: request.extensionID, version: request.version, presentationID: id,
            enginePID: engine.pid, engineGeneration: engine.generation,
            rendererPID: renderer.pid, rendererGeneration: renderer.generation,
            windowRegistration: windowRegistration)
        try origin.validate(request)
        return origin
    }

    public func herdrNotificationPresentations(version: String) -> [UUID] {
        presentations.compactMap { id, handle in
            guard handle.request.extensionID == "herdr", handle.request.location == "main",
                handle.configuration.worker.version == version, handle.isPresented,
                pendingCleanup[id] == nil
            else { return nil }
            return id
        }
    }

    public func herdrNotificationLease(
        presentationID: UUID, version: String,
        validateWindow: @escaping @MainActor () throws -> Void
    ) throws -> HostHerdrNotificationLease {
        guard let handle = presentations[presentationID], handle.request.extensionID == "herdr",
            handle.request.location == "main", handle.configuration.worker.version == version
        else { throw HostWorkerError.rejected }
        let request = HostWorkerNavigationRequest(
            configuration: handle.configuration.worker, presentationID: presentationID,
            location: "main")
        try validateNavigationOrigin(request)
        try validateWindow()
        guard let renderer = handle.processIdentity, renderer.isRunning else {
            throw HostWorkerError.rejected
        }
        let engine = try HostRemoteEngineOwner(
            marketplace: marketplace, configuration: selectedConfiguration(for: handle.request))
        return HostHerdrNotificationLease(
            configuration: handle.configuration.worker, presentationID: presentationID,
            enginePID: engine.process.pid, engineGeneration: engine.process.generation,
            validateOrigin: { [weak self, weak handle] in
                guard let self, let handle, self.presentations[presentationID] === handle,
                    handle.processIdentity == renderer, renderer.isRunning
                else {
                    throw HostWorkerError.rejected
                }
                try engine.validate()
                try self.validateNavigationOrigin(request)
                try validateWindow()
            },
            invoke: { operation, payload in
                try await engine.invoke(
                    .init(
                        presentationID: presentationID, operation: operation, payload: payload,
                        timeout: 5))
            })
    }

    public func herdrWindowLease(_ request: HostWorkerNavigationRequest) throws
        -> HostHerdrWindowLease
    {
        guard request.extensionID == "herdr", let target = request.herdrWindow,
            let id = request.presentationID, let handle = presentations[id]
        else { throw HostWorkerError.rejected }
        try validateNavigationOrigin(request)
        let engine = try HostRemoteEngineOwner(
            marketplace: marketplace,
            configuration: selectedConfiguration(for: handle.request))
        return HostHerdrWindowLease(
            target: target,
            invoke: { operation, payload in
                try await engine.invoke(
                    .init(
                        presentationID: id, operation: operation, payload: payload,
                        timeout: 5))
            },
            validateOrigin: { [weak self] in
                guard let self else { throw HostWorkerError.rejected }
                try self.validateNavigationOrigin(request)
            })
    }

    public func terminalUI(presentationID: UUID, event: HostTerminalUIEvent) async throws -> Bool {
        try await terminalClient(presentationID).update(event)
    }

    public func terminalUIStatus(presentationID: UUID) async throws -> HostTerminalUIStatus {
        try await terminalClient(presentationID).status()
    }

    private func terminalClient(_ id: UUID) throws -> HostTerminalSceneClient {
        if let client = terminalClients[id] { return client }
        let handle = try terminalHandle(id)
        let client = try HostTerminalSceneClient(
            current: { [weak self, weak handle] in
                guard let self, let handle, try self.terminalHandle(id) === handle,
                    let engine = handle.engineIdentity, let renderer = handle.processIdentity
                else { throw HostWorkerError.rejected }
                return HostTerminalSceneIdentity(
                    request: handle.request, package: handle.configuration.package,
                    session: handle.configuration.session, engine: engine, renderer: renderer)
            },
            update: { [weak handle] event in
                guard let handle else { throw HostWorkerError.rejected }
                return try await handle.terminalUI(event)
            },
            status: { [weak handle] in
                guard let handle else { throw HostWorkerError.rejected }
                return try await handle.terminalUIStatus()
            })
        terminalClients[id] = client
        return client
    }

    private func terminalHandle(_ id: UUID) throws -> any HostScenePresentation {
        guard let handle = presentations[id], HostTerminalUIRequest.accepts(handle.request),
            handle.isPresented, pendingCleanup[id] == nil,
            handle.processIdentity?.isRunning == true,
            marketplace.sessions.enabledIDs.contains(handle.request.extensionID),
            let pid = marketplace.sessions.processIdentifiers[handle.request.extensionID],
            handle.engineIdentity == (try HostRemoteKernelIdentity.read(pid))
        else { throw HostWorkerError.rejected }
        let current = try selectedConfiguration(for: handle.request)
        guard !current.uiOnly, current.package == handle.configuration.package,
            current.worker.version == handle.configuration.worker.version
        else { throw HostWorkerError.rejected }
        return handle
    }

    public func presentationCounts(excluding excluded: Set<UUID> = []) -> [String: Int] {
        var result: [String: Int] = [:]
        for (id, handle) in presentations where !excluded.contains(id) {
            result[handle.request.extensionID, default: 0] += 1
        }
        for (id, extensionID) in pendingCleanup
        where !excluded.contains(id) && presentations[id] == nil {
            result[extensionID, default: 0] += 1
        }
        return result
    }

    public func presentScene(
        _ handle: HostLocalSceneHandle, compact: Bool, visible: Bool, width: Double
    ) async throws -> NSViewController {
        var controller: NSViewController?
        try await ambientScene(handle, visible: visible) {
            controller = try handle.present(compact: compact, visible: visible, width: width)
        }
        guard let controller else { throw HostWorkerError.rejected }
        return controller
    }

    public func updateScene(
        _ handle: any HostScenePresentation, compact: Bool, visible: Bool, width: Double
    ) async throws {
        try await ambientScene(handle, visible: visible) {
            try await handle.update(compact: compact, visible: visible, width: width)
        }
    }

    private func ambientScene(
        _ handle: any HostScenePresentation, visible: Bool,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let request = handle.request
        guard
            let topic = HostAmbientPolicyCoordinator.topic(
                owner: request.extensionID, location: request.location, section: request.section)
        else { try await operation(); return }
        let owner = try ambientOwner(handle)
        try await marketplace.sessions.ambientPolicyCoordinator.updateScene(
            presentation: request.presentationID, owner: owner, job: topic, visible: visible,
            validate: {
                guard try self.ambientOwner(handle) == owner else { throw HostWorkerError.rejected }
            },
            validatePresented: {
                guard handle.isPresented, handle.processIdentity?.isRunning == true,
                    try self.ambientOwner(handle) == owner
                else { throw HostWorkerError.rejected }
            }, operation: operation)
    }

    private func ambientOwner(_ handle: any HostScenePresentation) throws
        -> HostAmbientPolicyOwner
    {
        let request = handle.request
        guard presentations[request.presentationID] === handle,
            pendingCleanup[request.presentationID] == nil, !handle.configuration.uiOnly
        else {
            throw HostWorkerError.rejected
        }
        let selected = try selectedConfiguration(for: request)
        guard !selected.uiOnly, selected.package == handle.configuration.package else {
            throw HostWorkerError.rejected
        }
        let engine = try HostRemoteEngineOwner(marketplace: marketplace, configuration: selected)
        guard engine.process == handle.engineIdentity, engine.process.isRunning else {
            throw HostWorkerError.rejected
        }
        return .init(
            id: request.extensionID, version: selected.package.version,
            processIdentifier: engine.process.pid, processGeneration: engine.process.generation)
    }

    public func prepareToClose(id: UUID) async throws {
        marketplace.sessions.ambientPolicyCoordinator.release(presentation: id)
        try await presentations[id]?.prepareToClose()
    }

    public func endPresentation(id: UUID) async throws {
        marketplace.sessions.ambientPolicyCoordinator.release(presentation: id)
        if let extensionID = pendingCleanup[id] {
            try await stop(extensionID: extensionID)
            pendingCleanup[id] = nil
            return
        }
        guard let handle = presentations[id] else { return }
        let extensionID = handle.request.extensionID
        try await handle.prepareToClose()
        do {
            try await handle.close()
        } catch {
            pendingCleanup[id] = extensionID
            try await stop(extensionID: extensionID)
            pendingCleanup[id] = nil
            return
        }
        presentations[id] = nil
        terminalClients[id] = nil
        do {
            try await stopUnused(extensionID: extensionID)
        } catch {
            pendingCleanup[id] = extensionID
            throw error
        }
    }

    private func finishAdmission(id: String, token: UUID) {
        admissions[id]?.remove(token)
        if admissions[id]?.isEmpty == true { admissions[id] = nil }
    }

    private func stopUnused(extensionID: String) async throws {
        guard admissions[extensionID] == nil,
            !presentations.values.contains(where: { $0.request.extensionID == extensionID })
        else { return }
        if let session = localSessions[extensionID], session.isIdle {
            session.stop()
            localSessions[extensionID] = nil
        }
    }

    public func stop(extensionID: String) async throws {
        marketplace.sessions.ambientPolicyCoordinator.release(owner: extensionID)
        detach(extensionID)
        localSessions.removeValue(forKey: extensionID)?.stop()
        terminalClients = terminalClients.filter {
            presentations[$0.key]?.request.extensionID != extensionID
        }
    }

    func selectedConfiguration(for request: HostExtensionContentRequest) throws
        -> HostRemoteConfiguration
    {
        try request.validate(extensionID: request.extensionID)
        guard marketplace.entries.contains(where: { $0.id == request.extensionID }),
            let package = marketplace.installed[request.extensionID],
            !marketplace.pendingRemovalIDs.contains(request.extensionID),
            !marketplace.sessions.pendingDisableIDs.contains(request.extensionID),
            marketplace.sessions.states[request.extensionID] != .stopping,
            package.hostABI == HostContract.compatibility, package.architecture == "arm64",
            package.minimumSystemVersion
                <= .init(ProcessInfo.processInfo.operatingSystemVersion)
        else { throw HostWorkerError.rejected }
        let active =
            marketplace.sessions.activeIDs.contains(request.extensionID)
            && marketplace.sessions.versions[request.extensionID] == package.version
        guard active || (request.location == "settings" && request.surface == nil) else {
            throw HostWorkerError.rejected
        }
        return HostRemoteConfiguration(
            session: UUID(),
            worker: HostWorkerConfiguration(
                identity: marketplace.identity, extensionID: package.id, version: package.version),
            package: package, uiOnly: !active)
    }
}

public enum HostRemoteAvailabilityError: LocalizedError {
    case approvalRequired
    public var errorDescription: String? {
        "Approve the installed extension in macOS extension settings before opening its interface."
    }
}

struct HostTerminalSceneIdentity: Equatable {
    let request: HostExtensionContentRequest
    let package: ExtensionPackage
    let session: UUID
    let engine: HostRemoteKernelIdentity
    let renderer: HostRemoteProcessIdentity

    func validate() throws {
        guard HostTerminalUIRequest.accepts(request), package.id == request.extensionID,
            engine.pid > 1, renderer.pid > 1, !engine.generation.isEmpty,
            !renderer.generation.isEmpty, !renderer.codeHash.isEmpty
        else { throw HostWorkerError.rejected }
    }
}

@MainActor
final class HostTerminalSceneClient {
    private let identity: HostTerminalSceneIdentity
    private let current: () throws -> HostTerminalSceneIdentity
    private let send: (HostTerminalUIEvent) async throws -> Bool
    private let read: () async throws -> HostTerminalUIStatus
    private var sequence: UInt64 = 0

    init(
        current: @escaping () throws -> HostTerminalSceneIdentity,
        update: @escaping (HostTerminalUIEvent) async throws -> Bool,
        status: @escaping () async throws -> HostTerminalUIStatus
    ) throws {
        identity = try current()
        try identity.validate()
        self.current = current; send = update; read = status
    }

    private func validate() throws {
        try Task.checkCancellation()
        let next = try current()
        try next.validate()
        guard next == identity else { throw HostWorkerError.rejected }
    }

    func update(_ event: HostTerminalUIEvent) async throws -> Bool {
        try validate()
        _ = try event.encoded(presentationID: identity.request.presentationID)
        guard event.sequence > sequence else { throw HostWorkerError.rejected }
        sequence = event.sequence
        let result = try await send(event)
        try validate()
        return result
    }

    func status() async throws -> HostTerminalUIStatus {
        try validate()
        let result = try await read()
        try validate()
        guard result.ok, result.presentationID == identity.request.presentationID else {
            throw HostWorkerError.invalidResponse
        }
        return result
    }
}
