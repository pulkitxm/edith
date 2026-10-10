@preconcurrency import ExtensionFoundation
import ExtensionMarketplace
import Foundation

@MainActor
public final class HostRemoteSessionManager {
    public var detach: @MainActor (String) -> Void = { _ in }
    public var receive: @MainActor (String, HostRemoteEvent) -> Void = { _, _ in }
    private let marketplace: HostMarketplace
    private var sessions: [String: HostRemoteSession] = [:]
    private var starting: [String: Task<HostRemoteSession, any Error>] = [:]
    private var presentations: [UUID: HostRemoteSceneHandle] = [:]
    private var admissions: [String: Set<UUID>] = [:]
    private var pendingCleanup: [UUID: String] = [:]
    var checkIn: @MainActor (HostRemoteConfiguration) async throws -> Void
    var discover: @MainActor (String) async throws -> [AppExtensionIdentity] = { point in
        try await Task.detached {
            var iterator = try AppExtensionIdentity.matching(appExtensionPointIDs: point)
                .makeAsyncIterator()
            return await iterator.next() ?? []
        }.value
    }

    public init(marketplace: HostMarketplace) {
        self.marketplace = marketplace
        checkIn = { configuration in
            try await HostRemoteCarrierCheckIn.register(
                configuration: configuration, store: marketplace.packageStore)
        }
        marketplace.sessions.willDisable = { [weak self] id in
            if let self {
                try await self.stop(extensionID: id)
            } else {
                try await HostRemoteCarrierCheckIn.stop(extensionID: id)
                try await HostRemoteSession.stopAll(extensionID: id)
            }
        }
    }

    public func scene(for request: HostExtensionContentRequest) async throws
        -> HostRemoteSceneHandle
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
        -> HostRemoteSceneHandle
    {
        try Task.checkCancellation()
        let configuration = try selectedConfiguration(for: request)
        let id = request.extensionID
        let engine =
            configuration.uiOnly
            ? nil
            : try HostRemoteEngineOwner(
                marketplace: marketplace, configuration: configuration)
        let session: HostRemoteSession
        if let current = sessions[id], current.configuration.package == configuration.package,
            current.configuration.uiOnly == configuration.uiOnly, current.peer?.isRunning == true,
            current.engineIdentity == engine?.process
        {
            session = current
        } else if let task = starting[id] {
            session = try await task.value
        } else {
            if let current = sessions[id] { detach(id); try await current.stop() }
            let task = Task { [self] in
                try await checkIn(configuration)
                try Task.checkCancellation()
                let identities = try await discover(
                    configuration.worker.identifier + ".ExtensionUI")
                try Task.checkCancellation()
                let identifier = configuration.worker.identifier + ".extension." + id + ".worker"
                guard let identity = identities.first(where: { $0.bundleIdentifier == identifier })
                else {
                    throw HostRemoteAvailabilityError.approvalRequired
                }
                let session = try await HostRemoteSession.start(
                    identity: identity, configuration: configuration,
                    store: marketplace.packageStore,
                    receive: { [weak self] event in self?.receive(id, event) },
                    engineIdentity: engine?.process,
                    executeEngine: { request in
                        guard let engine else { throw HostWorkerError.rejected }
                        return try await engine.invoke(request)
                    })
                if Task.isCancelled { try? await session.stop(); throw CancellationError() }
                session.didStop = { [weak self, weak session] in
                    guard let self, let session, self.sessions[id] === session else { return }
                    self.sessions[id] = nil
                    self.detach(id)
                    self.presentations = self.presentations.filter {
                        $0.value.request.extensionID != id
                    }
                }
                sessions[id] = session
                return session
            }
            starting[id] = task
            defer { starting[id] = nil }
            session = try await task.value
        }
        try Task.checkCancellation()
        let current = try selectedConfiguration(for: request)
        guard current.package == session.configuration.package,
            current.uiOnly == session.configuration.uiOnly,
            session.engineIdentity == engine?.process,
            engine?.process.isRunning ?? true
        else { try await session.stop(); throw HostWorkerError.rejected }
        let handle = try await session.reserve(request)
        presentations[request.presentationID] = handle
        return handle
    }

    public func prepareToClose(id: UUID) async throws {
        try await presentations[id]?.prepareToClose()
    }

    public func endPresentation(id: UUID) async throws {
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
        if admissions[id] == nil,
            !presentations.values.contains(where: { $0.request.extensionID == id })
        {
            starting[id]?.cancel()
        }
    }

    private func stopUnused(extensionID: String) async throws {
        guard admissions[extensionID] == nil,
            !presentations.values.contains(where: { $0.request.extensionID == extensionID })
        else { return }
        if let session = sessions[extensionID] { try await session.stop() }
    }

    public func stop(extensionID: String) async throws {
        starting[extensionID]?.cancel()
        if let task = starting[extensionID] { _ = try? await task.value }
        starting[extensionID] = nil
        detach(extensionID)
        try await HostRemoteCarrierCheckIn.stop(extensionID: extensionID)
        try await HostRemoteSession.stopAll(extensionID: extensionID)
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
                <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion
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
