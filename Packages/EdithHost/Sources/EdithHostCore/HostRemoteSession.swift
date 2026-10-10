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
    public var didAuthenticate: (@MainActor (String) -> Void)?
    public var didStop: (@MainActor () -> Void)?
    private static var retained: [UUID: HostRemoteSession] = [:]
    private let executable: URL
    private let executeEngine: HostRemoteEngineReceiver.Execute
    private let receive: @MainActor (HostRemoteEvent) -> Void
    private var configuring: Task<Void, any Error>?
    private var activationExpiry: Task<Void, Never>?
    public var isAvailable: Bool { !stopping && !stopped && (peer?.isRunning ?? true) }
    private var lease: PackageFileLock?
    private var process: AppExtensionProcess?
    private var launching: Task<AppExtensionProcess, any Error>?
    private var rejectedPeer: HostRemoteProcessIdentity?
    #if EDITH_CLI_FIXTURE
    fileprivate var fixtureRejectedPeers: [HostRemoteProcessIdentity] = []
    #endif
    private var bootstrap: NSXPCConnection?
    private var channel: HostRemoteChannel?
    private var handles: [UUID: HostRemoteSceneHandle] = [:]
    private var stopping = false
    private var stopped = false
    public static var extensionIDs: Set<String> {
        Set(retained.values.map { $0.configuration.package.id })
    }

    private init(
        identity: AppExtensionIdentity, configuration: HostRemoteConfiguration,
        executable: URL, lease: PackageFileLock, engineIdentity: HostRemoteKernelIdentity?,
        executeEngine: @escaping HostRemoteEngineReceiver.Execute,
        receive: @escaping @MainActor (HostRemoteEvent) -> Void
    ) {
        self.identity = identity
        self.configuration = configuration
        self.executable = executable
        self.lease = lease
        self.engineIdentity = engineIdentity
        self.executeEngine = executeEngine
        self.receive = receive
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
        let payload = store.directory(for: configuration.package).appendingPathComponent(
            configuration.package.id)
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
        guard
            identity.bundleIdentifier == carrier.workerIdentifier,
            identity.extensionPointIdentifier == carrier.extensionPointIdentifier,
            try HostRemoteKernelIdentity.read(getpid()).executable.path
                == carrier.hostExecutablePath
        else { throw HostWorkerError.rejected }
        let session = HostRemoteSession(
            identity: identity, configuration: configuration,
            executable: carrier.worker.appendingPathComponent("Contents/MacOS/Edith"), lease: lease,
            engineIdentity: engineIdentity, executeEngine: executeEngine, receive: receive)
        retained[configuration.session] = session
        session.activationExpiry = Task { [weak session] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let session, session.channel == nil else { return }
            try? await session.stop()
        }
        return session
    }

    public func reserve(_ request: HostExtensionContentRequest) async throws
        -> HostRemoteSceneHandle
    {
        guard isAvailable,
            handles.count < HostRemoteSceneDescriptor.maximumScenes,
            handles[request.presentationID] == nil,
            !configuration.uiOnly || (request.location == "settings" && request.surface == nil)
        else { throw HostWorkerError.rejected }
        try request.validate(extensionID: configuration.package.id)
        let slot = try (0..<HostRemoteSceneDescriptor.maximumScenes).first { index in
            let descriptor = try HostRemoteSceneDescriptor(
                slot: index, presentationID: request.presentationID)
            return !handles.values.contains { $0.sceneIdentifier == descriptor.sceneIdentifier }
        }
        guard let slot else { throw HostWorkerError.rejected }
        let handle = try HostRemoteSceneHandle(
            session: self, request: request,
            descriptor: HostRemoteSceneDescriptor(
                slot: slot, presentationID: request.presentationID))
        handles[request.presentationID] = handle
        return handle
    }

    fileprivate func rejectCandidate(_ bootstrap: NSXPCConnection) {
        guard peer == nil else { return }
        rejectedPeer =
            (try? HostRemoteProcessIdentity.read(bootstrap.processIdentifier)) ?? rejectedPeer
        process?.invalidate()
        process = nil
    }

    private func prepareProcess() async throws -> AppExtensionProcess {
        guard isAvailable else { throw HostWorkerError.exited }
        if let process { return process }
        if let launching { return try await launching.value }
        let selected = identity.id
        let task = Task { [self] in
            let process = try await AppExtensionProcess(
                configuration: AppExtensionProcess.Configuration(appExtensionIdentity: identity))
            guard isAvailable, identity.id == selected, !Task.isCancelled else {
                process.invalidate()
                throw HostWorkerError.exited
            }
            self.process = process
            return process
        }
        launching = task
        defer { launching = nil }
        return try await task.value
    }

    private func configure(peer: HostRemoteProcessIdentity) async throws {
        guard isAvailable, self.peer == nil || self.peer == peer else {
            throw HostWorkerError.rejected
        }
        self.peer = peer
        if channel != nil { return }
        if let configuring { return try await configuring.value }
        let task = Task { [self] in
            let process = try await prepareProcess()
            guard isAvailable, self.peer == peer else {
                process.invalidate(); throw HostWorkerError.exited
            }
            self.process = process
            let bootstrap = try process.makeXPCConnection()
            self.bootstrap = bootstrap
            let channel = try await HostRemoteChannel.connect(
                through: bootstrap, executable: executable, expectedPeer: peer, receive: receive)
            guard isAvailable, self.peer == peer else {
                channel.invalidate(); throw HostWorkerError.exited
            }
            _ = try await channel.request(
                HostRemoteCommand(
                    operation: "configure", payload: HostRemoteWire.encode(configuration)))
            try Task.checkCancellation()
            guard isAvailable else { channel.invalidate(); throw HostWorkerError.exited }
            self.channel = channel
            activationExpiry?.cancel()
            activationExpiry = nil
            didAuthenticate?(identity.id)
            channel.didInvalidate = { [weak self] in
                Task { @MainActor [weak self] in try? await self?.stop() }
            }
        }
        configuring = task
        defer { configuring = nil }
        do { try await task.value } catch {
            try? await stop(); throw error
        }
    }

    public func release(_ presentationID: UUID) async throws {
        guard let handle = handles[presentationID] else { return }
        if !stopping, !stopped, handle.isPresented { try await handle.prepareToClose() }
        handle.detach()
        guard !stopping, !stopped, let channel, handle.isReserved else {
            handles[presentationID] = nil
            return
        }
        _ = try await channel.request(
            HostRemoteCommand(operation: "release", payload: HostRemoteWire.encode(presentationID)))
        handles[presentationID] = nil
    }

    fileprivate func prepareToClose(_ presentationID: UUID) async throws {
        guard !stopping, !stopped, handles[presentationID] != nil, let channel else {
            throw HostWorkerError.exited
        }
        _ = try await channel.request(
            HostRemoteCommand(operation: "flush", payload: HostRemoteWire.encode(presentationID)),
            timeout: .seconds(3))
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
        activationExpiry?.cancel()
        activationExpiry = nil
        configuring?.cancel()
        launching?.cancel()
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
        if let rejectedPeer {
            let until = ContinuousClock.now + .seconds(3)
            while rejectedPeer.isRunning, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !rejectedPeer.isRunning else { throw HostWorkerError.stillRunning }
            self.rejectedPeer = nil
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
        _ = try await prepareProcess()
        let channel = try await HostRemoteChannel.connect(
            through: bootstrap, executable: executable, expectedPeer: peer,
            rejectedPeer: { [weak self] peer in
                self?.rejectedPeer = peer
                #if EDITH_CLI_FIXTURE
                self?.fixtureRejectedPeers.append(peer)
                #endif
            },
            receive: { event in
                guard event.presentationID == handle.presentationID else { return }
                receive(event)
            },
            executeEngine: { [weak self, weak handle] request in
                guard let self, let handle, !handle.closed, !self.stopping, !self.stopped,
                    !self.configuration.uiOnly, self.handles[handle.presentationID] === handle,
                    request.presentationID == handle.presentationID, handle.isReserved,
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
        do {
            guard let peer = channel.peer, handles[handle.presentationID] === handle else {
                throw HostWorkerError.rejected
            }
            try await configure(peer: peer)
            guard isAvailable, self.peer == channel.peer, handles[handle.presentationID] === handle,
                let control = self.channel
            else { throw HostWorkerError.rejected }
            let reservation = HostRemoteReservation(
                request: handle.request, sceneIdentifier: handle.sceneIdentifier)
            let reply = try await control.request(
                HostRemoteCommand(operation: "reserve", payload: HostRemoteWire.encode(reservation))
            )
            let descriptor = try HostRemoteWire.decode(
                HostRemoteSceneDescriptor.self, from: reply.payload)
            guard descriptor.presentationID == handle.presentationID,
                descriptor.sceneIdentifier == handle.sceneIdentifier,
                handles[handle.presentationID] === handle, isAvailable
            else { throw HostWorkerError.invalidResponse }
            handle.isReserved = true
            return channel
        } catch {
            channel.invalidate()
            if peer == nil { process?.invalidate(); process = nil }
            throw error
        }
    }
}

@MainActor
public final class HostRemoteSceneHandle {
    public let request: HostExtensionContentRequest
    public let sceneIdentifier: String
    public var presentationID: UUID { request.presentationID }
    public var identity: AppExtensionIdentity { session.identity }
    public var isPresented: Bool { presented && !closed }
    public var processIdentity: HostRemoteProcessIdentity? { session.peer }
    public var configuration: HostRemoteConfiguration { session.configuration }
    public var engineIdentity: HostRemoteKernelIdentity? { session.engineIdentity }
    #if EDITH_CLI_FIXTURE
    public var fixtureRejectedProcesses: [HostRemoteProcessIdentity] {
        session.fixtureRejectedPeers
    }
    #endif
    private let session: HostRemoteSession
    private var channel: HostRemoteChannel?
    private var bootstrap: NSXPCConnection?
    fileprivate var closed = false
    fileprivate var isReserved = false
    private var presented = false
    private var preparedToClose = false
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
            if session.peer == nil { session.rejectCandidate(bootstrap) }
            bootstrap.invalidate()
            self.bootstrap = nil
            if session.peer != nil { try? await close() }
            throw error
        }
    }

    public func update(compact: Bool, visible: Bool, width: Double) async throws {
        guard !closed else { throw HostWorkerError.rejected }
        desired = try context(compact: compact, visible: visible, width: width)
        guard presented, let desired else { return }
        try await send("update", presentation: desired)
    }

    public func terminalUI(_ event: HostTerminalUIEvent) async throws -> Bool {
        let data = try await terminalRequest(operation: .update, event: event)
        struct Reply: Decodable { let ok: Bool }
        guard !data.isEmpty, data.count <= 1024 else { throw HostWorkerError.invalidResponse }
        return try JSONDecoder().decode(Reply.self, from: data).ok
    }

    public func terminalUIStatus() async throws -> HostTerminalUIStatus {
        let data = try await terminalRequest(operation: .status)
        return try HostTerminalUIStatus.decode(data, presentationID: presentationID)
    }

    private func terminalRequest(
        operation: HostTerminalUIRequest.Operation, event: HostTerminalUIEvent? = nil
    ) async throws -> Data {
        guard !closed, !preparedToClose, presented, let channel, session.isAvailable,
            !configuration.uiOnly, engineIdentity?.isRunning == true,
            channel.peer == processIdentity
        else { throw HostWorkerError.rejected }
        let input = HostTerminalUIRequest(
            session: configuration.session, request: self.request, operation: operation,
            event: event)
        let reply = try await channel.request(
            HostRemoteCommand(operation: operation.rawValue, payload: input.encoded()),
            timeout: .seconds(2))
        try Task.checkCancellation()
        guard !closed, !preparedToClose, self.channel === channel, session.isAvailable,
            engineIdentity?.isRunning == true, channel.peer == processIdentity
        else { throw HostWorkerError.rejected }
        return reply.payload
    }

    public func close() async throws {
        try await session.release(presentationID)
    }

    public func prepareToClose() async throws {
        guard !closed else { throw HostWorkerError.exited }
        guard presented else { return }
        guard !preparedToClose else { return }
        try await session.prepareToClose(presentationID)
        guard !closed else { throw HostWorkerError.exited }
        preparedToClose = true
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
