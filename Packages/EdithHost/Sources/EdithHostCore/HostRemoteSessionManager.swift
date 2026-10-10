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

    public init(marketplace: HostMarketplace) {
        self.marketplace = marketplace
        marketplace.sessions.willDisable = { [weak self] id in
            if let self {
                try await self.stop(extensionID: id)
            } else {
                try await HostRemoteSession.stopAll(extensionID: id)
            }
        }
    }

    public func scene(for request: HostExtensionContentRequest) async throws
        -> HostRemoteSceneHandle
    {
        let configuration = try selectedConfiguration(for: request)
        let id = request.extensionID
        let session: HostRemoteSession
        if let current = sessions[id], current.configuration.package == configuration.package,
            current.configuration.uiOnly == configuration.uiOnly, current.peer?.isRunning == true
        {
            session = current
        } else if let task = starting[id] {
            session = try await task.value
        } else {
            if let current = sessions[id] { detach(id); try await current.stop() }
            let task = Task { [self] in
                let identities = try await Task.detached {
                    var iterator = try AppExtensionIdentity.matching(
                        appExtensionPointIDs: configuration.worker.identifier + ".ExtensionUI"
                    )
                    .makeAsyncIterator()
                    return await iterator.next() ?? []
                }.value
                try Task.checkCancellation()
                let identifier = configuration.worker.identifier + ".extension." + id + ".worker"
                guard let identity = identities.first(where: { $0.bundleIdentifier == identifier })
                else {
                    throw HostRemoteAvailabilityError.approvalRequired
                }
                let session = try await HostRemoteSession.start(
                    identity: identity, configuration: configuration,
                    store: marketplace.packageStore,
                    receive: { [weak self] event in
                        self?.receive(id, event)
                    })
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
            current.uiOnly == session.configuration.uiOnly
        else { try await session.stop(); throw HostWorkerError.rejected }
        let handle = try await session.reserve(request)
        presentations[request.presentationID] = handle
        return handle
    }

    public func endPresentation(id: UUID) async throws {
        guard let handle = presentations.removeValue(forKey: id) else { return }
        try await handle.close()
        let extensionID = handle.request.extensionID
        if let session = sessions[extensionID], session.configuration.uiOnly,
            !presentations.values.contains(where: { $0.request.extensionID == extensionID })
        {
            try await session.stop()
        }
    }

    public func stop(extensionID: String) async throws {
        starting[extensionID]?.cancel()
        if let task = starting[extensionID] { _ = try? await task.value }
        starting[extensionID] = nil
        detach(extensionID)
        try await HostRemoteSession.stopAll(extensionID: extensionID)
    }

    func selectedConfiguration(for request: HostExtensionContentRequest) throws
        -> HostRemoteConfiguration
    {
        try request.validate(extensionID: request.extensionID)
        guard marketplace.entries.contains(where: { $0.id == request.extensionID }),
            let package = marketplace.installed[request.extensionID],
            !marketplace.pendingRemovalIDs.contains(request.extensionID),
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
