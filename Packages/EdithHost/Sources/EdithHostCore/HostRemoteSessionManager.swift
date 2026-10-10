@preconcurrency import ExtensionFoundation
import ExtensionMarketplace
import Foundation

@MainActor
public final class HostRemoteSessionManager {
    #if EDITH_CLI_FIXTURE
    public private(set) var fixtureIdentities: [[String: String]] = []
    private var fixturePreferredIdentity: String?

    public func fixturePrioritizeRetained(_ package: ExtensionPackage) async throws {
        guard marketplace.identity.identifier.hasPrefix("com.pulkit.edith.tests.remote-"),
            package.id == "sample",
            try marketplace.packageStore.installedPackages().contains(package)
        else { throw HostWorkerError.rejected }
        let request = HostExtensionContentRequest(
            extensionID: "sample", location: "settings", section: "extension")
        let selected = try selectedConfiguration(for: request)
        guard selected.package.version != package.version else { throw HostWorkerError.rejected }
        let point = selected.worker.identifier + ".ExtensionUI"
        let previous = Set(try await discover(point).map(\.id))
        let worker = HostWorkerConfiguration(
            identity: try selected.worker.identity(), extensionID: package.id,
            version: package.version)
        try await checkIn(
            HostRemoteConfiguration(
                session: UUID(), worker: worker, package: package, uiOnly: true), {})
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            let added = try await discover(point).filter {
                !previous.contains($0.id)
                    && $0.bundleIdentifier == selected.worker.identifier
                        + ".extension.sample.worker"
            }
            if added.count == 1 { fixturePreferredIdentity = added[0].id; return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw HostWorkerError.timedOut
    }
    #endif
    public var detach: @MainActor (String) -> Void = { _ in }
    public var receive: @MainActor (String, HostRemoteEvent) -> Void = { _, _ in }
    private let marketplace: HostMarketplace
    private var sessions: [String: HostRemoteSession] = [:]
    private var starting: [String: Task<HostRemoteSession, any Error>] = [:]
    private var presentations: [UUID: HostRemoteSceneHandle] = [:]
    private var terminalClients: [UUID: HostTerminalSceneClient] = [:]
    private var admissions: [String: Set<UUID>] = [:]
    private var pendingCleanup: [UUID: String] = [:]
    private var verifiedIdentities: [String: (package: ExtensionPackage, identity: String)] = [:]
    var checkIn:
        @MainActor (HostRemoteConfiguration, @escaping @MainActor () async throws -> Void)
            async throws -> Void
    var discover: @MainActor (String) async throws -> [AppExtensionIdentity] = { point in
        try await Task.detached {
            var iterator = try AppExtensionIdentity.matching(appExtensionPointIDs: point)
                .makeAsyncIterator()
            return await iterator.next() ?? []
        }.value
    }

    public init(marketplace: HostMarketplace) {
        self.marketplace = marketplace
        checkIn = { configuration, beforeRegistration in
            try await HostRemoteCarrierCheckIn.register(
                configuration: configuration, store: marketplace.packageStore,
                beforeRegistration: beforeRegistration)
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
            current.configuration.uiOnly == configuration.uiOnly, current.isAvailable,
            current.engineIdentity == engine?.process
        {
            session = current
        } else if let task = starting[id] {
            session = try await task.value
        } else {
            if let current = sessions[id] { detach(id); try await current.stop() }
            let task = Task { [self] in
                let point = configuration.worker.identifier + ".ExtensionUI"
                let identifier = configuration.worker.identifier + ".extension." + id + ".worker"
                var baseline: Set<String>?
                try await checkIn(configuration) {
                    let identities = try await self.discover(point)
                    baseline = try HostRemoteIdentitySelection.ids(
                        identities.filter { $0.bundleIdentifier == identifier }.map(\.id))
                }
                try Task.checkCancellation()
                guard let baseline else { throw HostWorkerError.rejected }
                let identities = try await discover(point)
                try Task.checkCancellation()
                let matching = identities.filter { $0.bundleIdentifier == identifier }
                #if EDITH_CLI_FIXTURE
                fixtureIdentities = matching.prefix(64).map {
                    ["id": $0.id, "bundleIdentifier": $0.bundleIdentifier]
                }
                #endif
                guard !matching.isEmpty else { throw HostRemoteAvailabilityError.approvalRequired }
                let preferred = verifiedIdentities[id].flatMap {
                    $0.package == configuration.package ? $0.identity : nil
                }
                var selectedID = try HostRemoteIdentitySelection.select(
                    before: baseline, after: matching.map(\.id), verified: preferred)
                #if EDITH_CLI_FIXTURE
                if let fixturePreferredIdentity { selectedID = fixturePreferredIdentity }
                #endif
                guard let identity = matching.first(where: { $0.id == selectedID }) else {
                    throw HostWorkerError.rejected
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
                session.didAuthenticate = { [weak self] identity in
                    self?.verifiedIdentities[id] = (configuration.package, identity)
                }
                session.didStop = { [weak self, weak session] in
                    guard let self, let session, self.sessions[id] === session else { return }
                    self.sessions[id] = nil
                    self.detach(id)
                    self.terminalClients = self.terminalClients.filter {
                        self.presentations[$0.key]?.request.extensionID != id
                    }
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

    private func terminalHandle(_ id: UUID) throws -> HostRemoteSceneHandle {
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
        terminalClients = terminalClients.filter {
            presentations[$0.key]?.request.extensionID != extensionID
        }
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
