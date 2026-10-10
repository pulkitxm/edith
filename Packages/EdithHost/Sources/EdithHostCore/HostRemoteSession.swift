import Darwin
import EdithExtensionSupport
@preconcurrency import ExtensionFoundation
import ExtensionMarketplace
import Foundation

@MainActor
public final class HostRemoteSession {
    public let identity: AppExtensionIdentity
    public let configuration: HostRemoteConfiguration
    public let engineIdentity: HostRemoteKernelIdentity?
    public private(set) var peer: HostRemoteProcessIdentity?
    public var didStop: (@MainActor () -> Void)?
    private static var retained: [UUID: HostRemoteSession] = [:]
    private let executable: URL
    private let executeEngine: HostRemoteEngineReceiver.Execute
    private var lease: PackageFileLock?
    private var process: AppExtensionProcess?
    private var bootstrap: NSXPCConnection?
    private var channel: HostRemoteChannel?
    private var handles: [UUID: HostRemoteSceneHandle] = [:]
    private var reservations = Set<UUID>()
    private var stopping = false
    private var stopped = false
    public static var extensionIDs: Set<String> {
        Set(retained.values.map { $0.configuration.package.id })
    }

    private init(
        identity: AppExtensionIdentity, configuration: HostRemoteConfiguration,
        executable: URL, lease: PackageFileLock, engineIdentity: HostRemoteKernelIdentity?,
        executeEngine: @escaping HostRemoteEngineReceiver.Execute
    ) {
        self.identity = identity
        self.configuration = configuration
        self.executable = executable
        self.lease = lease
        self.engineIdentity = engineIdentity
        self.executeEngine = executeEngine
    }

    public static func start(
        identity: AppExtensionIdentity, configuration: HostRemoteConfiguration,
        store: ExtensionPackageStore,
        receive: @escaping @MainActor (HostRemoteEvent) -> Void = { _ in },
        engineIdentity: HostRemoteKernelIdentity? = nil,
        executeEngine:
            @escaping @MainActor @Sendable (ExtensionEngineRequest) async throws -> Data = {
                _ in throw HostWorkerError.rejected
            }
    ) async throws -> HostRemoteSession {
        guard configuration.uiOnly == (engineIdentity == nil),
            engineIdentity?.isRunning ?? true,
            retained.count < 64, retained[configuration.session] == nil,
            configuration.package.hostABI == HostContract.compatibility,
            configuration.package.architecture == "arm64",
            configuration.package.minimumSystemVersion
                <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            try !store.pendingRemovals().contains(configuration.package.id)
        else { throw HostWorkerError.rejected }
        try configuration.validate(
            hostIdentifier: configuration.worker.identifier, extensionID: configuration.package.id,
            version: configuration.package.version)
        let lease = try store.lease(configuration.package)
        let payload = store.directory(for: configuration.package)
        let development = try configuration.worker.identity().development
        let team = ExtensionCodeSignature.teamIdentifier()
        let carrier = try await Task.detached(priority: .userInitiated) {
            let carrier = try ExtensionUICarrier(
                payload: payload, package: configuration.package,
                expectedHostIdentifier: configuration.worker.identifier)
            if development {
                try carrier.verifyDevelopment()
            } else {
                guard let team else { throw MarketplaceError.invalidSignature }
                try carrier.verify(teamIdentifier: team)
            }
            return carrier
        }.value
        try Task.checkCancellation()
        guard identity.bundleIdentifier == carrier.workerIdentifier,
            identity.extensionPointIdentifier == carrier.extensionPointIdentifier,
            try HostRemoteKernelIdentity.read(getpid()).executable.path
                == carrier.hostExecutablePath
        else { throw HostWorkerError.rejected }
        let session = HostRemoteSession(
            identity: identity, configuration: configuration,
            executable: carrier.worker.appendingPathComponent("Contents/MacOS/Edith"), lease: lease,
            engineIdentity: engineIdentity, executeEngine: executeEngine)
        retained[configuration.session] = session
        do {
            let process = try await AppExtensionProcess(
                configuration: AppExtensionProcess.Configuration(appExtensionIdentity: identity))
            session.process = process
            let bootstrap = try process.makeXPCConnection()
            session.bootstrap = bootstrap
            let channel = try await Task { @MainActor in
                try await HostRemoteChannel.connect(
                    through: bootstrap, executable: session.executable, receive: receive)
            }.value
            session.channel = channel
            session.peer = channel.peer
            try Task.checkCancellation()
            channel.didInvalidate = { [weak session] in
                Task { @MainActor [weak session] in try? await session?.stop() }
            }
            _ = try await channel.request(
                HostRemoteCommand(
                    operation: "configure", payload: HostRemoteWire.encode(configuration)))
            try Task.checkCancellation()
            return session
        } catch {
            try? await session.stop()
            throw error
        }
    }

    public func reserve(_ request: HostExtensionContentRequest) async throws
        -> HostRemoteSceneHandle
    {
        guard !stopping, !stopped, peer?.isRunning == true, let channel,
            handles.count + reservations.count < HostRemoteSceneDescriptor.maximumScenes,
            handles[request.presentationID] == nil,
            !reservations.contains(request.presentationID),
            !configuration.uiOnly || (request.location == "settings" && request.surface == nil)
        else { throw HostWorkerError.rejected }
        try request.validate(extensionID: configuration.package.id)
        reservations.insert(request.presentationID)
        defer { reservations.remove(request.presentationID) }
        do {
            let result = try await channel.request(
                HostRemoteCommand(operation: "reserve", payload: HostRemoteWire.encode(request)))
            try Task.checkCancellation()
            guard !stopping, !stopped, peer?.isRunning == true else {
                throw HostWorkerError.exited
            }
            let descriptor = try HostRemoteWire.decode(
                HostRemoteSceneDescriptor.self, from: result.payload)
            guard descriptor.presentationID == request.presentationID,
                (0..<HostRemoteSceneDescriptor.maximumScenes).contains(where: {
                    descriptor.sceneIdentifier == "edith-ui-\($0)"
                }),
                !handles.values.contains(where: { $0.sceneIdentifier == descriptor.sceneIdentifier }
                )
            else { throw HostWorkerError.invalidResponse }
            let handle = HostRemoteSceneHandle(
                session: self, request: request, descriptor: descriptor)
            handles[request.presentationID] = handle
            return handle
        } catch {
            let release = await Task { @MainActor in
                try? await channel.request(
                    HostRemoteCommand(
                        operation: "release", payload: HostRemoteWire.encode(request.presentationID)
                    ),
                    timeout: .seconds(3))
            }.value
            if release == nil { try? await stop() }
            throw error
        }
    }

    public func release(_ presentationID: UUID) async throws {
        guard let handle = handles[presentationID] else { return }
        handle.detach()
        guard !stopping, !stopped, let channel else {
            handles[presentationID] = nil
            return
        }
        _ = try await channel.request(
            HostRemoteCommand(operation: "release", payload: HostRemoteWire.encode(presentationID)))
        handles[presentationID] = nil
    }

    public static func stopAll(extensionID: String) async throws {
        var failure: Error?
        for session in Array(retained.values) where session.configuration.package.id == extensionID
        {
            do { try await session.stop() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    public func stop() async throws {
        guard !stopped else { return }
        guard !stopping else { throw HostWorkerError.stillRunning }
        stopping = true
        defer { stopping = false }
        handles.values.forEach { $0.detach() }
        handles.removeAll()
        if let channel {
            _ = try? await channel.request(
                HostRemoteCommand(operation: "stop"), timeout: .seconds(3))
            channel.didInvalidate = nil
            channel.invalidate()
        }
        channel = nil
        bootstrap?.invalidate()
        bootstrap = nil
        process?.invalidate()
        process = nil
        if let peer {
            for _ in 0..<30 where peer.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if peer.isRunning { _ = kill(peer.pid, SIGKILL) }
            for _ in 0..<20 where peer.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            guard !peer.isRunning else { throw HostWorkerError.stillRunning }
        }
        stopped = true
        lease?.close()
        lease = nil
        Self.retained[configuration.session] = nil
        didStop?()
    }

    fileprivate func connect(
        handle: HostRemoteSceneHandle, bootstrap: NSXPCConnection,
        receive: @escaping @MainActor (HostRemoteEvent) -> Void
    ) async throws -> HostRemoteChannel {
        guard !stopping, !stopped, handles[handle.presentationID] === handle else {
            throw HostWorkerError.rejected
        }
        let channel = try await HostRemoteChannel.connect(
            through: bootstrap, executable: executable, expectedPeer: peer,
            receive: { event in
                guard event.presentationID == handle.presentationID else { return }
                receive(event)
            },
            executeEngine: { [weak self, weak handle] request in
                guard let self, let handle, !handle.closed, !self.stopping, !self.stopped,
                    !self.configuration.uiOnly, self.handles[handle.presentationID] === handle,
                    request.presentationID == handle.presentationID,
                    self.engineIdentity?.isRunning == true
                else { throw HostWorkerError.rejected }
                let result = try await self.executeEngine(request)
                try Task.checkCancellation()
                guard !handle.closed, !self.stopping, !self.stopped,
                    self.handles[handle.presentationID] === handle,
                    self.engineIdentity?.isRunning == true
                else { throw HostWorkerError.rejected }
                return result
            })
        guard channel.peer == peer, peer?.isRunning == true,
            handles[handle.presentationID] === handle
        else { channel.invalidate(); throw HostWorkerError.rejected }
        return channel
    }
}

@MainActor
public final class HostRemoteSceneHandle {
    public let request: HostExtensionContentRequest
    public let sceneIdentifier: String
    public var presentationID: UUID { request.presentationID }
    public var identity: AppExtensionIdentity { session.identity }
    private let session: HostRemoteSession
    private var channel: HostRemoteChannel?
    private var bootstrap: NSXPCConnection?
    fileprivate var closed = false
    private var presented = false
    private var desired: HostRemotePresentation?

    fileprivate init(
        session: HostRemoteSession, request: HostExtensionContentRequest,
        descriptor: HostRemoteSceneDescriptor
    ) {
        self.session = session
        self.request = request
        sceneIdentifier = descriptor.sceneIdentifier
    }

    public func connect(
        through bootstrap: NSXPCConnection, compact: Bool, visible: Bool, width: Double,
        receive: @escaping @MainActor (HostRemoteEvent) -> Void = { _ in }
    ) async throws {
        guard !closed, channel == nil, self.bootstrap == nil else { throw HostWorkerError.rejected }
        self.bootstrap = bootstrap
        if desired == nil {
            desired = try context(compact: compact, visible: visible, width: width)
        }
        do {
            let channel = try await session.connect(
                handle: self, bootstrap: bootstrap, receive: receive)
            guard !closed, let initial = desired else {
                channel.invalidate()
                throw HostWorkerError.exited
            }
            self.channel = channel
            try await send("present", presentation: initial)
            presented = true
            if let latest = desired, latest != initial {
                try await send("update", presentation: latest)
            }
        } catch {
            try? await close()
            throw error
        }
    }

    public func update(compact: Bool, visible: Bool, width: Double) async throws {
        guard !closed else { throw HostWorkerError.rejected }
        desired = try context(compact: compact, visible: visible, width: width)
        guard presented, let desired else { return }
        try await send("update", presentation: desired)
    }

    public func close() async throws {
        try await session.release(presentationID)
    }

    fileprivate func detach() {
        closed = true
        channel?.invalidate()
        channel = nil
        bootstrap?.invalidate()
        bootstrap = nil
    }

    private func context(compact: Bool, visible: Bool, width: Double) throws
        -> HostRemotePresentation
    {
        let presentation = HostRemotePresentation(
            session: session.configuration.session, request: request, compact: compact,
            visible: visible, availableWidth: width)
        try presentation.validate(
            session: session.configuration.session, extensionID: request.extensionID)
        return presentation
    }

    private func send(_ operation: String, presentation: HostRemotePresentation) async throws {
        guard let channel, !closed else { throw HostWorkerError.rejected }
        _ = try await channel.request(
            HostRemoteCommand(operation: operation, payload: HostRemoteWire.encode(presentation)))
    }
}
