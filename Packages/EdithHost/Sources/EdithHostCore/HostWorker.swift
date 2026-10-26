import Darwin
import EdithExtensionSupport
import Foundation

@MainActor
public protocol HostWorkerEngine: AnyObject {
    func perform(_ request: HostWorkerRequest) async -> HostWorkerResponse
    func deliver(_ reply: HostWorkerNavigationReply) throws
}

@MainActor
public final class HostWorkerChannel {
    fileprivate weak var worker: HostWorker?

    public func navigate(_ request: HostWorkerNavigationRequest) throws {
        guard let worker else { throw HostWorkerError.exited }
        do { try request.validate(configuration: worker.configuration) } catch {
            worker.terminateForViolation()
            throw error
        }
        try worker.receiveNavigation(request)
    }

    public func cancelNavigation(_ cancel: HostWorkerNavigationCancel) throws {
        guard let worker else { throw HostWorkerError.exited }
        try cancel.validate(configuration: worker.configuration)
        worker.finishNavigation(cancel.token, request: nil, ok: false)
    }

    public func processGroup(_ resource: HostWorkerProcessGroup) throws {
        guard let worker else { throw HostWorkerError.exited }
        try worker.receive(resource)
    }
}

@MainActor
public final class HostWorker {

    public let generation = UUID()
    public private(set) var configuration: HostWorkerConfiguration
    public private(set) var ready = false
    public private(set) var requiresRecovery = false
    public var didExit: (@MainActor () -> Void)?
    public var didRequestNavigation:
        (@MainActor (HostWorkerNavigationRequest) async throws -> Void)?
    public var didRequestFolderChoice:
        (@MainActor (HostWorkerNavigationRequest) async throws -> HostFolderChoiceResult)?
    public var processIdentifier: Int32? { running ? getpid() : nil }
    public var isStopped: Bool {
        ownedProcessGroups.refresh(owner: getpid())
        return !running && ownedProcessGroups.isEmpty
    }

    private struct NavigationPending {
        let request: HostWorkerNavigationRequest
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
    }

    private let requestTimeout: Duration
    private let channel = HostWorkerChannel()
    private var engine: (any HostWorkerEngine)?
    private var running = false
    private var launched = false
    private var busy = false
    private var navigation: [UUID: NavigationPending] = [:]
    private var preparation: (operation: String, response: HostWorkerResponse?)?
    private var ownedProcessGroups = HostWorkerProcessGroups()
    private var groupRefresh: Task<Void, Never>?
    private var exitNotified = false
    private var stopAcknowledged = false

    private let makeEngine: @MainActor (HostWorkerChannel) -> any HostWorkerEngine

    public init(
        configuration: HostWorkerConfiguration, requestTimeout: Duration = .seconds(15),
        engine: @escaping @MainActor (HostWorkerChannel) -> any HostWorkerEngine = {
            HostInProcessWorkerEngine(channel: $0)
        }
    ) {
        self.configuration = configuration
        self.requestTimeout = requestTimeout
        makeEngine = engine
        channel.worker = self
    }

    public func start(recoveryOnly: Bool = false) async throws {
        guard !launched else { throw HostWorkerError.rejected }
        launched = true
        configuration.recoveryOnly = recoveryOnly
        requiresRecovery = recoveryOnly
        do {
            try sharedState()?.clear(configuration.extensionID)
            engine = makeEngine(channel)
            running = true
            let response = try await request(
                HostWorkerRequest(operation: "start", configuration: configuration))
            guard response.version == configuration.version else {
                throw HostWorkerError.invalidResponse
            }
            groupRefresh = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.ownedProcessGroups.refresh(owner: getpid())
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            ready = true
        } catch {
            await finish(reason: .shutdown)
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

    public func preventsQuit() async -> Bool {
        guard ready,
            let response = try? await request(
                HostWorkerRequest(operation: "quitStatus"), timeout: .seconds(2))
        else { return false }
        return response.message == HostWorkerResponse.preventsQuitMessage
    }

    public func prepareDisable(timeout: Duration? = nil) async throws {
        try await prepare(operation: "prepareDisable", timeout: timeout)
    }

    public func prepareStop(reason: HostWorkerStopReason) async throws {
        if reason == .applicationQuit, configuration.extensionID == "lidAwake",
            !configuration.recoveryOnly
        {
            try await prepare(operation: "prepareApplicationQuit", reason: reason)
        } else if reason != .applicationQuit {
            try await prepareDisable()
        }
    }

    public func stop(reason: HostWorkerStopReason = .disable) async throws {
        guard running || !requiresRecovery else {
            throw HostWorkerError.disableRejected("Cleanup must be retried in a recovery worker.")
        }
        try await prepareStop(reason: reason)
        ready = false
        var failure: Error?
        if running {
            do {
                let response = try await request(
                    HostWorkerRequest(operation: "stop", stopReason: reason),
                    timeout: min(requestTimeout, .seconds(3)))
                guard response.version == configuration.version else {
                    throw HostWorkerError.invalidResponse
                }
                stopAcknowledged = true
            } catch {
                requiresRecovery = true
                failure = failure ?? error
            }
        }
        await finish(reason: reason)
        try await awaitOwnedExit()
        notifyExit()
        if let failure { throw failure }
        guard !requiresRecovery else {
            throw HostWorkerError.disableRejected("Cleanup must be retried in a recovery worker.")
        }
    }

    private func prepare(
        operation: String, reason: HostWorkerStopReason? = nil, timeout: Duration? = nil
    ) async throws {
        guard running else { return }
        ready = false
        cancelNavigation(acknowledge: true)
        if let preparation, let response = preparation.response, response.ok {
            guard preparation.operation == operation else { throw HostWorkerError.rejected }
            return
        }
        preparation = (operation, nil)
        let response: HostWorkerResponse
        do {
            response = try await request(
                HostWorkerRequest(operation: operation, stopReason: reason), timeout: timeout,
                acceptsFailure: true)
        } catch {
            requiresRecovery = true
            throw error
        }
        guard !response.ok || response.version == configuration.version else {
            requiresRecovery = true
            await finish(reason: reason ?? .disable)
            throw HostWorkerError.invalidResponse
        }
        preparation = (operation, response)
        requiresRecovery = !response.ok
        guard response.ok else {
            let message = response.message.flatMap { $0.isEmpty || $0.count > 1024 ? nil : $0 }
            throw HostWorkerError.disableRejected(
                message
                    ?? "Cleanup is pending. Restore system settings or finish macOS approval, then try again."
            )
        }
    }

    private func request(
        _ request: HostWorkerRequest, timeout: Duration? = nil, acceptsFailure: Bool = false
    ) async throws -> HostWorkerResponse {
        guard running, let engine else { throw HostWorkerError.exited }
        guard !busy else { throw HostWorkerError.rejected }
        busy = true
        defer { busy = false }
        let limit = timeout ?? requestTimeout
        let outcome = HostWorkerOutcome()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.begin(continuation)
                Task { @MainActor in outcome.finish(.success(await engine.perform(request))) }
                Task { @MainActor in
                    try? await Task.sleep(for: limit)
                    outcome.finish(.failure(HostWorkerError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor in outcome.finish(.failure(CancellationError())) }
        }
        guard response.token == request.token else { throw HostWorkerError.invalidResponse }
        guard response.ok || acceptsFailure else {
            if request.operation == "start", let message = response.message,
                !message.isEmpty, message.count <= 1024
            {
                throw HostWorkerError.startRejected(message)
            }
            throw HostWorkerError.rejected
        }
        return response
    }

    fileprivate func terminateForViolation() {
        Task { @MainActor in await finish(reason: .ownerLost) }
    }

    fileprivate func receiveNavigation(_ request: HostWorkerNavigationRequest) throws {
        guard ready, !configuration.recoveryOnly, preparation == nil,
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

    fileprivate func finishNavigation(
        _ token: UUID, request: HostWorkerNavigationRequest?, ok: Bool,
        folderResult: HostFolderChoiceResult? = nil
    ) {
        guard let pending = navigation.removeValue(forKey: token) else { return }
        pending.task.cancel()
        pending.deadline.cancel()
        guard let request, ready else { return }
        let admitted = ok && !configuration.recoveryOnly && preparation == nil
        try? acknowledgeNavigation(
            request, ok: admitted, folderResult: admitted ? folderResult : nil)
    }

    private func acknowledgeNavigation(
        _ request: HostWorkerNavigationRequest, ok: Bool,
        folderResult: HostFolderChoiceResult? = nil
    ) throws {
        guard running, let engine else { throw HostWorkerError.exited }
        try engine.deliver(
            HostWorkerNavigationReply(request: request, ok: ok, folderResult: folderResult))
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

    fileprivate func receive(_ resource: HostWorkerProcessGroup) throws {
        guard running, resource.pid != getpid() else { throw HostWorkerError.invalidResponse }
        if resource.registered {
            guard let identity = ExtensionProcessIdentity.read(resource.pid),
                identity.generation == resource.generation,
                ExtensionNativeTask.isDescendant(resource.pid, of: getpid())
            else { throw HostWorkerError.invalidResponse }
            try ownedProcessGroups.register(resource, owner: getpid())
        } else {
            ownedProcessGroups.release(resource, owner: getpid())
        }
    }

    private func finish(reason: HostWorkerStopReason) async {
        guard let engine else { return }
        running = false
        ready = false
        cancelNavigation()
        groupRefresh?.cancel()
        groupRefresh = nil
        self.engine = nil
        if !stopAcknowledged {
            Task { @MainActor in
                _ = await engine.perform(HostWorkerRequest(operation: "stop", stopReason: reason))
            }
        }
        ownedProcessGroups.terminate(owner: getpid())
    }

    private func awaitOwnedExit() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            ownedProcessGroups.refresh(owner: getpid())
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
}

@MainActor
private final class HostWorkerOutcome {
    private var continuation: CheckedContinuation<HostWorkerResponse, any Error>?
    private var early: Result<HostWorkerResponse, any Error>?

    func begin(_ continuation: CheckedContinuation<HostWorkerResponse, any Error>) {
        if let early {
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<HostWorkerResponse, any Error>) {
        guard let continuation else {
            if early == nil { early = result }
            return
        }
        continuation.resume(with: result)
        self.continuation = nil
        early = result
    }
}
