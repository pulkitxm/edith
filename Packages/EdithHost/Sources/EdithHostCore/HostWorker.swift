import Darwin
import EdithExtensionSupport
import Foundation

@MainActor
public final class HostWorker {
    #if EDITH_FUNCTIONAL_FIXTURE
    public struct FixtureStopReceipt: Codable, Sendable {
        public let configuration: HostWorkerConfiguration
        public let reason: HostWorkerStopReason
        public let worker: ExtensionProcessIdentity?
        public let preparationRequest: HostWorkerRequest?
        public let preparationResponse: HostWorkerResponse?
        public let stopRequest: HostWorkerRequest?
        public let stopResponse: HostWorkerResponse?
        public let observedBirths: [ExtensionProcessIdentity]
        public let signalAttempts: [HostWorkerSignalAttempt]
        public let terminationStatus: Int32?
        public let terminationReason: Int?
    }
    public static var fixtureBeforeConfiguration:
        ((HostWorker, ExtensionProcessIdentity) async throws -> Void)?
    public static var fixtureObserveStop: ((FixtureStopReceipt) throws -> Void)?
    #endif
    private struct Pending {
        let continuation: CheckedContinuation<HostWorkerResponse, any Error>
        let timeout: Task<Void, Never>
    }

    public private(set) var configuration: HostWorkerConfiguration
    public private(set) var ready = false
    public private(set) var requiresRecovery = false
    public var didExit: (@MainActor () -> Void)?
    public var didRequestNavigation:
        (@MainActor (HostWorkerNavigationRequest) async throws -> Void)?
    public var didRequestFolderChoice:
        (@MainActor (HostWorkerNavigationRequest) async throws -> HostFolderChoiceResult)?
    public var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let requestTimeout: Duration
    private var frames = HostWorkerFrames()
    private var pending: [UUID: Pending] = [:]
    private var abandoned = Set<UUID>()
    private struct NavigationPending {
        let request: HostWorkerNavigationRequest
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
    }
    private var navigation: [UUID: NavigationPending] = [:]
    private var preparationToken: UUID?
    private var preparationTokens = Set<UUID>()
    private var preparationRequest: HostWorkerRequest?
    private var preparationResponse: HostWorkerResponse?
    private var workerIdentity: ExtensionProcessIdentity?
    private var launched = false
    private var exited = false
    private var ownedProcessGroups = HostWorkerProcessGroups()
    private var groupRefresh: Task<Void, Never>?
    private var exitDrain: Task<Void, Never>?
    private var exitNotified = false
    public var isStopped: Bool {
        ownedProcessGroups.refresh(owner: process.processIdentifier)
        return !process.isRunning && ownedProcessGroups.isEmpty
    }
    private var readSource: DispatchSourceRead?
    private var outputIsNonblocking = false

    public init(
        configuration: HostWorkerConfiguration, executable: URL,
        arguments: [String] = ["--extension-worker"], requestTimeout: Duration = .seconds(15),
        errorOutput: FileHandle = .nullDevice
    ) {
        self.configuration = configuration
        self.requestTimeout = requestTimeout
        process.executableURL = executable
        process.arguments = arguments
        if let identity = try? configuration.identity() {
            var environment = ProcessInfo.processInfo.environment
            environment["EDITH_APPLICATION_IDENTIFIER"] = identity.identifier
            environment["EDITH_SHARED_DEFAULTS_SUITE"] = identity.extensionDefaultsSuite(
                configuration.extensionID)
            environment["EDITH_EXTENSION_DATA_ROOT"] =
                identity.extensionDirectory(configuration.extensionID).path
            environment["EDITH_SURFACE_DEFAULTS_SUITE"] = identity.applicationDefaultsSuite
            environment["EDITH_EXTENSION_ID"] = configuration.extensionID
            environment["EDITH_EXTENSION_STATE_ROOT"] =
                identity.root.appendingPathComponent("ExtensionState").path
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
    }

    public func start(recoveryOnly: Bool = false) async throws {
        guard !launched else { throw HostWorkerError.rejected }
        configuration.recoveryOnly = recoveryOnly
        var environment = process.environment ?? ProcessInfo.processInfo.environment
        environment["EDITH_EXTENSION_RECOVERY_ONLY"] = recoveryOnly ? "1" : nil
        process.environment = environment
        launched = true
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HostWorkerError.exited
        }
        outputIsNonblocking = true
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainOutput() }
        }
        readSource = source
        source.resume()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        do {
            try sharedState()?.clear(configuration.extensionID)
            try process.run()
            guard let birth = ExtensionProcessIdentity.read(process.processIdentifier) else {
                throw HostWorkerError.invalidResponse
            }
            workerIdentity = birth
            try ownedProcessGroups.captureWorker(birth)
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            #if EDITH_FUNCTIONAL_FIXTURE
            guard let prepare = Self.fixtureBeforeConfiguration else {
                throw HostWorkerError.rejected
            }
            try await prepare(self, birth)
            try Task.checkCancellation()
            guard workerIdentity == birth, birth.isAlive, process.isRunning else {
                throw HostWorkerError.rejected
            }
            #endif
            let response = try await request(
                HostWorkerRequest(operation: "start", configuration: configuration))
            guard response.version == configuration.version else {
                throw HostWorkerError.invalidResponse
            }
            guard getpgid(process.processIdentifier) == process.processIdentifier else {
                throw HostWorkerError.invalidResponse
            }
            guard let identity = ExtensionProcessIdentity.read(process.processIdentifier) else {
                throw HostWorkerError.invalidResponse
            }
            try ownedProcessGroups.register(
                HostWorkerProcessGroup(
                    pid: identity.pid, generation: identity.generation, registered: true),
                owner: process.processIdentifier)
            groupRefresh = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let owner = self?.process.processIdentifier else { return }
                    self?.ownedProcessGroups.refresh(owner: owner)
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            ready = true
        } catch {
            terminate()
            try? await awaitExit()
            try? await awaitOwnedExit()
            throw error
        }
    }

    public func show() async throws {
        guard ready else { throw HostWorkerError.rejected }
        _ = try await request(HostWorkerRequest(operation: "show"))
    }

    public func synchronize(configuration: HostWorkerConfiguration? = nil) async throws {
        try await synchronize(.settings, configuration: configuration ?? self.configuration)
    }

    func synchronizeAmbientPolicy(configuration: HostWorkerConfiguration) async throws {
        try await synchronize(.ambientPolicy, configuration: configuration)
    }

    private func synchronize(
        _ route: HostWorkerSynchronization, configuration next: HostWorkerConfiguration
    ) async throws {
        guard ready else { throw HostWorkerError.rejected }
        let current = configuration
        let acknowledged = try await route.acknowledged(current: current, next: next) {
            try await self.request($0)
        }
        guard ready, configuration.identifier == current.identifier,
            configuration.extensionID == current.extensionID,
            configuration.version == current.version
        else { throw HostWorkerError.rejected }
        configuration = acknowledged
    }

    public func status() async throws -> HostWorkerResponse {
        guard ready else { throw HostWorkerError.rejected }
        return try await request(HostWorkerRequest(operation: "status"))
    }

    public func prepareDisable(timeout: Duration? = nil) async throws {
        try await prepare(operation: "prepareDisable", timeout: timeout)
    }

    private func prepare(
        operation: String, reason: HostWorkerStopReason? = nil, timeout: Duration? = nil
    ) async throws {
        guard launched, !exited, process.isRunning else { return }
        guard let workerIdentity, workerIdentity.isAlive else { throw HostWorkerError.exited }
        guard pending.isEmpty else { throw HostWorkerError.rejected }
        ready = false
        cancelNavigation(acknowledge: true)
        if let preparationResponse {
            if preparationResponse.ok {
                guard preparationRequest?.operation == operation else {
                    throw HostWorkerError.rejected
                }
                return
            }
            self.preparationResponse = nil
            preparationRequest = nil
            preparationToken = nil
        }
        let request =
            preparationRequest
            ?? HostWorkerRequest(operation: operation, stopReason: reason)
        guard request.operation == operation else { throw HostWorkerError.rejected }
        guard preparationTokens.count < 64 || preparationTokens.contains(request.token) else {
            throw HostWorkerError.rejected
        }
        preparationTokens.insert(request.token)
        preparationRequest = request
        preparationToken = request.token
        _ = try await self.request(request, timeout: timeout)
    }

    public func prepareStop(reason: HostWorkerStopReason) async throws {
        if reason == .applicationQuit, configuration.extensionID == "lidAwake",
            !configuration.recoveryOnly
        {
            try await prepare(operation: "prepareApplicationQuit", reason: reason)
        } else {
            try await prepareDisable()
        }
    }

    public func stop(reason: HostWorkerStopReason = .disable) async throws {
        guard !isStopped || !requiresRecovery else {
            throw HostWorkerError.disableRejected("Cleanup must be retried in a recovery worker.")
        }
        try await prepareStop(reason: reason)
        ready = false
        var failure: Error?
        #if EDITH_FUNCTIONAL_FIXTURE
        var stopRequest: HostWorkerRequest?
        var stopResponse: HostWorkerResponse?
        #endif
        if process.isRunning {
            do {
                let stop = HostWorkerRequest(operation: "stop", stopReason: reason)
                #if EDITH_FUNCTIONAL_FIXTURE
                stopRequest = stop
                #endif
                let response = try await request(
                    stop,
                    timeout: min(requestTimeout, .seconds(3)))
                #if EDITH_FUNCTIONAL_FIXTURE
                stopResponse = response
                #endif
                guard response.version == configuration.version else {
                    throw HostWorkerError.invalidResponse
                }
            } catch {
                requiresRecovery = true
                failure = error
            }
            try? input.fileHandleForWriting.close()
            do { try await awaitExit() } catch {
                terminate()
                try await awaitExit()
            }
        }
        finish()
        terminateGroup()
        try await awaitOwnedExit()
        notifyExit()
        if let failure { throw failure }
        guard !requiresRecovery else {
            throw HostWorkerError.disableRejected("Cleanup must be retried in a recovery worker.")
        }
        #if EDITH_FUNCTIONAL_FIXTURE
        guard let observe = Self.fixtureObserveStop else { throw HostWorkerError.rejected }
        let terminated = process.processIdentifier > 1 && !process.isRunning
        try observe(
            FixtureStopReceipt(
                configuration: configuration, reason: reason, worker: workerIdentity,
                preparationRequest: preparationRequest, preparationResponse: preparationResponse,
                stopRequest: stopRequest, stopResponse: stopResponse,
                observedBirths: ownedProcessGroups.observedBirths,
                signalAttempts: ownedProcessGroups.signalAttempts,
                terminationStatus: terminated ? process.terminationStatus : nil,
                terminationReason: terminated ? process.terminationReason.rawValue : nil))
        #endif
    }

    private func request(_ request: HostWorkerRequest, timeout: Duration? = nil) async throws
        -> HostWorkerResponse
    {
        guard process.isRunning, !exited else { throw HostWorkerError.exited }
        guard pending.isEmpty, abandoned.count < 64 else { throw HostWorkerError.rejected }
        let data = try HostWorkerFrames.encode(request)
        let requestTimeout = timeout ?? self.requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    self?.cancelRequest(request.token, error: HostWorkerError.timedOut)
                }
                pending[request.token] = Pending(continuation: continuation, timeout: timeout)
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch { fail(error) }
                if Task.isCancelled { cancelRequest(request.token, error: CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(request.token, error: CancellationError())
            }
        }
    }

    private func receive(_ bytes: Data) {
        guard !exited else { return }
        guard !bytes.isEmpty else {
            readSource?.cancel()
            readSource = nil
            if !pending.isEmpty || !navigation.isEmpty { fail(HostWorkerError.exited) }
            return
        }
        do {
            for data in try frames.append(bytes) {
                if let resource = try? JSONDecoder().decode(
                    HostWorkerProcessGroup.self, from: data),
                    resource.kind == "processGroup"
                {
                    try receive(resource)
                    continue
                }
                if let request = try? JSONDecoder().decode(
                    HostWorkerNavigationRequest.self, from: data), request.kind == "navigation"
                {
                    try request.validate(configuration: configuration)
                    try receiveNavigation(request)
                    continue
                }
                if let cancel = try? JSONDecoder().decode(
                    HostWorkerNavigationCancel.self, from: data), cancel.kind == "navigationCancel"
                {
                    try cancel.validate(configuration: configuration)
                    finishNavigation(cancel.token, request: nil, ok: false)
                    continue
                }
                let response = try JSONDecoder().decode(HostWorkerResponse.self, from: data)
                if response.token == preparationToken {
                    guard let workerIdentity, workerIdentity.isAlive,
                        (!response.ok && response.version == nil)
                            || response.version == configuration.version
                    else { throw HostWorkerError.invalidResponse }
                    preparationResponse = response
                    requiresRecovery = !response.ok
                    abandoned.remove(response.token)
                    guard pending[response.token] != nil else { continue }
                } else if preparationTokens.contains(response.token) {
                    continue
                } else if abandoned.remove(response.token) != nil {
                    continue
                }
                guard let request = pending.removeValue(forKey: response.token) else {
                    throw HostWorkerError.invalidResponse
                }
                request.timeout.cancel()
                if response.ok {
                    request.continuation.resume(returning: response)
                } else {
                    if response.token == preparationToken {
                        let message = response.message.flatMap {
                            $0.isEmpty || $0.count > 1024 ? nil : $0
                        }
                        request.continuation.resume(
                            throwing: HostWorkerError.disableRejected(
                                message
                                    ?? "Cleanup is pending. Restore system settings or finish macOS approval, then try again."
                            ))
                    } else {
                        request.continuation.resume(throwing: HostWorkerError.rejected)
                    }
                }
            }
        } catch { fail(HostWorkerError.invalidResponse) }
    }

    private func drainOutput() {
        guard !exited, outputIsNonblocking else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                receive(Data(buffer.prefix(count)))
            } else if count == 0 {
                receive(Data())
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                fail(HostWorkerError.exited)
                return
            }
        }
    }

    private func receiveNavigation(_ request: HostWorkerNavigationRequest) throws {
        guard ready, !configuration.recoveryOnly, preparationToken == nil,
            request.folderChoice == true
                ? didRequestFolderChoice != nil : didRequestNavigation != nil
        else { try acknowledgeNavigation(request, ok: false); return }
        guard navigation.count < 8, navigation[request.token] == nil else {
            throw HostWorkerError.invalidResponse
        }
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self else { throw HostWorkerError.rejected }
                let result: HostFolderChoiceResult?
                if request.folderChoice == true {
                    guard let choose = self.didRequestFolderChoice else {
                        throw HostWorkerError.rejected
                    }
                    result = try await choose(request)
                    try result?.validate()
                } else {
                    guard let navigate = self.didRequestNavigation else {
                        throw HostWorkerError.rejected
                    }
                    try await navigate(request)
                    result = nil
                }
                try Task.checkCancellation()
                self.finishNavigation(
                    request.token, request: request, ok: true, folderResult: result)
            } catch { self?.finishNavigation(request.token, request: request, ok: false) }
        }
        let deadline = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: request.folderChoice == true ? .seconds(120) : .seconds(5))
            } catch { return }
            self?.finishNavigation(request.token, request: request, ok: false)
        }
        navigation[request.token] = NavigationPending(
            request: request, task: task, deadline: deadline)
    }

    private func finishNavigation(
        _ token: UUID, request: HostWorkerNavigationRequest?, ok: Bool,
        folderResult: HostFolderChoiceResult? = nil
    ) {
        guard let pending = navigation.removeValue(forKey: token) else { return }
        pending.task.cancel()
        pending.deadline.cancel()
        guard let request, ready else { return }
        do {
            let admitted = ok && !configuration.recoveryOnly && preparationToken == nil
            try acknowledgeNavigation(
                request, ok: admitted, folderResult: admitted ? folderResult : nil)
        } catch { fail(HostWorkerError.invalidResponse) }
    }

    private func acknowledgeNavigation(
        _ request: HostWorkerNavigationRequest, ok: Bool,
        folderResult: HostFolderChoiceResult? = nil
    ) throws {
        guard process.isRunning else { throw HostWorkerError.exited }
        let reply = HostWorkerRequest(
            token: request.token, operation: "navigationReply",
            navigation: HostWorkerNavigationReply(
                request: request, ok: ok, folderResult: folderResult))
        var bytes = try JSONEncoder().encode(reply)
        guard bytes.count <= HostWorkerFrames.maximumBytes else {
            throw HostWorkerError.invalidResponse
        }
        bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    private func cancelNavigation(acknowledge: Bool = false) {
        let values = Array(navigation.values)
        navigation.removeAll()
        for value in values {
            value.task.cancel()
            value.deadline.cancel()
            if acknowledge { try? acknowledgeNavigation(value.request, ok: false) }
        }
    }

    private func receive(_ resource: HostWorkerProcessGroup) throws {
        guard resource.pid != process.processIdentifier else {
            throw HostWorkerError.invalidResponse
        }
        if resource.registered {
            try ownedProcessGroups.register(resource, owner: process.processIdentifier)
        } else {
            ownedProcessGroups.release(resource, owner: process.processIdentifier)
        }
    }

    private func cancelRequest(_ token: UUID, error: any Error) {
        guard token == preparationToken else { fail(error); return }
        guard let request = pending.removeValue(forKey: token) else { return }
        ready = false
        requiresRecovery = true
        abandoned.insert(token)
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func fail(_ error: any Error) {
        if preparationToken != nil { requiresRecovery = true }
        cancelNavigation()
        ready = false
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        terminate()
    }

    private func terminate() {
        cancelNavigation()
        terminateGroup()
        if process.isRunning, let workerIdentity, workerIdentity.isAlive {
            ownedProcessGroups.terminateCaptured(workerIdentity)
        }
    }

    private func terminateGroup() {
        groupRefresh?.cancel()
        groupRefresh = nil
        ownedProcessGroups.terminate(owner: process.processIdentifier)
    }

    private func awaitExit() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func awaitOwnedExit() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            ownedProcessGroups.refresh(owner: process.processIdentifier)
            if ownedProcessGroups.isEmpty { return }
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func notifyExit() {
        guard !exitNotified, isStopped else { return }
        exitNotified = true
        try? sharedState()?.clear(configuration.extensionID)
        didExit?()
    }

    private func sharedState() -> ExtensionSharedState? {
        guard let identity = try? configuration.identity() else { return nil }
        return ExtensionSharedState(
            root: identity.root.appendingPathComponent("ExtensionState"),
            namespace: identity.identifier)
    }

    private func finish() {
        guard !exited else { return }
        drainOutput()
        exited = true
        ready = false
        cancelNavigation()
        readSource?.cancel()
        readSource = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: HostWorkerError.exited)
        }
        terminateGroup()
        exitDrain = Task { [self] in
            do { try await awaitOwnedExit(); notifyExit() } catch {}
        }
    }
}
