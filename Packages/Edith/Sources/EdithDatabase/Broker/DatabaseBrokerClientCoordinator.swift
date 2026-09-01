import Dispatch
import Foundation

public enum DatabaseBrokerAvailabilityError: Error, Equatable, Sendable {
    case readinessTimedOut
    case versionTransitionTimedOut
    case unsafePeer
    case outcomeUnknown
    case unavailable
}

enum DatabaseBrokerClientProbeOutcome: Equatable, Sendable {
    case ready(UUID)
    case notReady(UUID)
    case socketMissing
    case connectionRefused
    case trustedVersionMismatch
    case retryableFailure
    case deadlineExceeded
    case unsafePeer
    case outcomeUnknown
    case unavailable
}

struct DatabaseBrokerClientProbe: Sendable {
    let perform: @Sendable (UInt64) -> DatabaseBrokerClientProbeOutcome
}

enum DatabaseBrokerClientLiveWorkerError: Error, Equatable, Sendable {
    case deadlineExceeded
    case launchNotCommitted
}

final class DatabaseBrokerClientLaunchOwnership: @unchecked Sendable {
    private let stateLock = NSLock()
    private var revoked = false
    private var leases: [DatabaseBrokerExecutableLaunchLease] = []

    func makeLease(
        deadlineNanoseconds: UInt64,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64
    ) -> DatabaseBrokerExecutableLaunchLease? {
        stateLock.withLock {
            guard !revoked else { return nil }
            let lease = DatabaseBrokerExecutableLaunchLease(
                deadlineNanoseconds: deadlineNanoseconds,
                monotonicNanoseconds: monotonicNanoseconds)
            leases.append(lease)
            return lease
        }
    }

    func revoke() {
        stateLock.withLock {
            guard !revoked else { return }
            revoked = true
            for lease in leases {
                lease.revoke()
            }
            leases.removeAll(keepingCapacity: false)
        }
    }
}

struct DatabaseBrokerClientDeadlineCancellation: Sendable {
    private let cancelImplementation: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        cancelImplementation = cancel
    }

    func cancel() {
        cancelImplementation()
    }
}

struct DatabaseBrokerClientLiveLauncher: Sendable {
    let launch: @Sendable (DatabaseBrokerExecutableLaunchLease) throws -> Void
}

struct DatabaseBrokerClientLiveWorkerDependencies: Sendable {
    let monotonicNanoseconds: @Sendable () -> UInt64
    let scheduleDeadline:
        @Sendable (
            UInt64,
            @escaping @Sendable () -> Void
        ) -> DatabaseBrokerClientDeadlineCancellation
    let prepareProbe: @Sendable () throws -> DatabaseBrokerClientProbe
    let prepareLauncher: @Sendable () throws -> DatabaseBrokerClientLiveLauncher
}

final class DatabaseBrokerClientLiveWorker: @unchecked Sendable {
    private let dependencies: DatabaseBrokerClientLiveWorkerDependencies
    private let queue: DispatchQueue
    private var preparedProbe: DatabaseBrokerClientProbe?
    private var preparedLauncher: DatabaseBrokerClientLiveLauncher?
    private var committedUntilNanoseconds: UInt64?

    init(
        dependencies: DatabaseBrokerClientLiveWorkerDependencies,
        queue: DispatchQueue = DispatchQueue(
            label: "com.edith.database.broker.client-live-worker")
    ) {
        self.dependencies = dependencies
        self.queue = queue
    }

    func makeProbe(
        deadlineNanoseconds: UInt64
    ) async throws -> DatabaseBrokerClientProbe {
        let work = makeWork(
            deadlineNanoseconds: deadlineNanoseconds,
            valueType: DatabaseBrokerClientProbe.self)
        queue.async { [self, work] in
            guard work.isPending else { return }
            guard dependencies.monotonicNanoseconds() < deadlineNanoseconds else {
                work.cancel(DatabaseBrokerClientLiveWorkerError.deadlineExceeded)
                return
            }
            if let preparedProbe {
                work.finish(
                    .success(preparedProbe),
                    before: deadlineNanoseconds,
                    monotonicNanoseconds: dependencies.monotonicNanoseconds)
                return
            }
            do {
                let probe = try dependencies.prepareProbe()
                preparedProbe = probe
                guard
                    work.isPending,
                    dependencies.monotonicNanoseconds() < deadlineNanoseconds
                else {
                    work.cancel(DatabaseBrokerClientLiveWorkerError.deadlineExceeded)
                    return
                }
                work.finish(
                    .success(probe),
                    before: deadlineNanoseconds,
                    monotonicNanoseconds: dependencies.monotonicNanoseconds)
            } catch {
                work.finish(.failure(error))
            }
        }
        return try await work.value()
    }

    func launch(
        deadlineNanoseconds: UInt64,
        ownership: DatabaseBrokerClientLaunchOwnership
    ) async throws {
        let work = makeWork(
            deadlineNanoseconds: deadlineNanoseconds,
            valueType: Void.self)
        queue.async { [self, work] in
            let now = dependencies.monotonicNanoseconds()
            guard work.isPending, now < deadlineNanoseconds else {
                work.cancel(DatabaseBrokerClientLiveWorkerError.deadlineExceeded)
                return
            }
            if let committedUntilNanoseconds, now < committedUntilNanoseconds {
                work.finish(
                    .success(()),
                    before: deadlineNanoseconds,
                    monotonicNanoseconds: dependencies.monotonicNanoseconds)
                return
            }
            committedUntilNanoseconds = nil
            do {
                let launcher: DatabaseBrokerClientLiveLauncher
                if let preparedLauncher {
                    launcher = preparedLauncher
                } else {
                    launcher = try dependencies.prepareLauncher()
                    preparedLauncher = launcher
                }
                guard
                    work.isPending,
                    dependencies.monotonicNanoseconds() < deadlineNanoseconds
                else {
                    work.cancel(DatabaseBrokerClientLiveWorkerError.deadlineExceeded)
                    return
                }
                guard
                    let lease = ownership.makeLease(
                        deadlineNanoseconds: deadlineNanoseconds,
                        monotonicNanoseconds: dependencies.monotonicNanoseconds)
                else {
                    work.cancel(CancellationError())
                    return
                }
                work.registerRevocation {
                    lease.revoke()
                }
                guard work.isPending else { return }
                try launcher.launch(lease)
                guard lease.isCommitted else {
                    work.finish(
                        .failure(
                            DatabaseBrokerClientLiveWorkerError.launchNotCommitted))
                    return
                }
                committedUntilNanoseconds = max(
                    committedUntilNanoseconds ?? 0,
                    deadlineNanoseconds)
                work.finish(
                    .success(()),
                    before: deadlineNanoseconds,
                    monotonicNanoseconds: dependencies.monotonicNanoseconds)
            } catch DatabaseBrokerExecutableLaunchLeaseError.notPermitted {
                if dependencies.monotonicNanoseconds() >= deadlineNanoseconds {
                    work.cancel(DatabaseBrokerClientLiveWorkerError.deadlineExceeded)
                } else {
                    work.cancel(CancellationError())
                }
            } catch {
                work.finish(.failure(error))
            }
        }
        try await work.value()
    }

    private func makeWork<Value: Sendable>(
        deadlineNanoseconds: UInt64,
        valueType _: Value.Type
    ) -> DatabaseBrokerClientLiveWork<Value> {
        let work = DatabaseBrokerClientLiveWork<Value>()
        let cancellation = dependencies.scheduleDeadline(deadlineNanoseconds) {
            work.cancel(DatabaseBrokerClientLiveWorkerError.deadlineExceeded)
        }
        work.installDeadlineCancellation(cancellation)
        return work
    }
}

private final class DatabaseBrokerClientLiveWork<Value: Sendable>:
    @unchecked Sendable
{
    private let stateLock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadlineCancellation: DatabaseBrokerClientDeadlineCancellation?
    private var revocations: [@Sendable () -> Void] = []

    var isPending: Bool {
        stateLock.withLock { result == nil }
    }

    func installDeadlineCancellation(
        _ cancellation: DatabaseBrokerClientDeadlineCancellation
    ) {
        let cancelImmediately = stateLock.withLock {
            guard result == nil else { return true }
            deadlineCancellation = cancellation
            return false
        }
        if cancelImmediately {
            cancellation.cancel()
        }
    }

    func registerRevocation(_ action: @escaping @Sendable () -> Void) {
        stateLock.withLock {
            guard result == nil else {
                action()
                return
            }
            revocations.append(action)
        }
    }

    func finish(_ newResult: Result<Value, Error>) {
        resolve {
            (newResult, false)
        }
    }

    func finish(
        _ newResult: Result<Value, Error>,
        before deadlineNanoseconds: UInt64,
        monotonicNanoseconds: @Sendable () -> UInt64
    ) {
        resolve {
            if monotonicNanoseconds() < deadlineNanoseconds {
                return (newResult, false)
            }
            return (
                .failure(DatabaseBrokerClientLiveWorkerError.deadlineExceeded),
                true
            )
        }
    }

    func cancel(_ error: Error) {
        resolve {
            (.failure(error), true)
        }
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                let completedResult = stateLock.withLock {
                    guard result == nil else { return result }
                    continuation = newContinuation
                    return nil
                }
                if let completedResult {
                    newContinuation.resume(with: completedResult)
                }
            }
        } onCancel: {
            cancel(CancellationError())
        }
    }

    private func resolve(
        _ makeResolution: () -> (Result<Value, Error>, Bool)
    ) {
        var newResult: Result<Value, Error>?
        let resolution:
            (
                CheckedContinuation<Value, Error>?,
                DatabaseBrokerClientDeadlineCancellation?
            )? = stateLock.withLock {
                guard result == nil else { return nil }
                let proposedResolution = makeResolution()
                newResult = proposedResolution.0
                let revoke = proposedResolution.1
                if revoke {
                    for action in revocations {
                        action()
                    }
                }
                result = proposedResolution.0
                let resolution = (continuation, deadlineCancellation)
                continuation = nil
                deadlineCancellation = nil
                revocations.removeAll(keepingCapacity: false)
                return resolution
            }
        guard let resolution, let newResult else { return }
        resolution.1?.cancel()
        resolution.0?.resume(with: newResult)
    }
}

struct DatabaseBrokerClientCoordinatorDependencies: Sendable {
    let monotonicNanoseconds: @Sendable () -> UInt64
    let sleep: @Sendable (UInt64) async throws -> Void
    let makeProbe: @Sendable (UInt64) async throws -> DatabaseBrokerClientProbe
    let launch:
        @Sendable (
            UInt64,
            DatabaseBrokerClientLaunchOwnership
        ) async throws -> Void

    init(
        monotonicNanoseconds: @escaping @Sendable () -> UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        makeProbe:
            @escaping @Sendable (UInt64) async throws -> DatabaseBrokerClientProbe,
        launch:
            @escaping @Sendable (
                UInt64,
                DatabaseBrokerClientLaunchOwnership
            ) async throws -> Void
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.sleep = sleep
        self.makeProbe = makeProbe
        self.launch = launch
    }
}

public actor DatabaseBrokerClientCoordinator {
    public static let shared = DatabaseBrokerClientCoordinator(
        dependencies: .live)

    static let readinessBudgetNanoseconds: UInt64 = 3_000_000_000
    static let versionTransitionBudgetNanoseconds: UInt64 = 10_000_000_000
    static let initialBackoffNanoseconds: UInt64 = 10_000_000
    static let maximumBackoffNanoseconds: UInt64 = 100_000_000

    private struct ActiveReadiness {
        let generation: UUID
        let launchOwnership: DatabaseBrokerClientLaunchOwnership
        let task: Task<Void, Error>
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let cancellation: DatabaseBrokerClientWaiterCancellation
    }

    private let dependencies: DatabaseBrokerClientCoordinatorDependencies
    private var activeReadiness: ActiveReadiness?
    private var waiters: [UUID: Waiter] = [:]

    init(dependencies: DatabaseBrokerClientCoordinatorDependencies) {
        self.dependencies = dependencies
    }

    public func ensureReady() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let cancellation = DatabaseBrokerClientWaiterCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[waiterID] = Waiter(
                        continuation: continuation,
                        cancellation: cancellation)
                    startReadinessIfNeeded()
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func startReadinessIfNeeded() {
        guard activeReadiness == nil else { return }
        let generation = UUID()
        let launchOwnership = DatabaseBrokerClientLaunchOwnership()
        let dependencies = dependencies
        let task = Task.detached(priority: .userInitiated) {
            try await Self.waitUntilReady(
                dependencies: dependencies,
                launchOwnership: launchOwnership)
        }
        activeReadiness = ActiveReadiness(
            generation: generation,
            launchOwnership: launchOwnership,
            task: task)
        Task {
            let result = await task.result
            completeReadiness(
                generation: generation,
                result: result)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.continuation.resume(
            throwing: CancellationError())
        guard waiters.isEmpty, let activeReadiness else { return }
        self.activeReadiness = nil
        activeReadiness.launchOwnership.revoke()
        activeReadiness.task.cancel()
    }

    private func completeReadiness(
        generation: UUID,
        result: Result<Void, Error>
    ) {
        guard
            let activeReadiness,
            activeReadiness.generation == generation
        else {
            return
        }
        self.activeReadiness = nil
        activeReadiness.launchOwnership.revoke()
        let completedWaiters = waiters.values
        waiters.removeAll(keepingCapacity: true)
        for waiter in completedWaiters {
            if waiter.cancellation.isCancelled {
                waiter.continuation.resume(throwing: CancellationError())
                continue
            }
            switch result {
            case .success:
                waiter.continuation.resume()
            case .failure(let error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    func pendingWaiterCount() -> Int {
        waiters.count
    }

    private static func waitUntilReady(
        dependencies: DatabaseBrokerClientCoordinatorDependencies,
        launchOwnership: DatabaseBrokerClientLaunchOwnership
    ) async throws {
        try Task.checkCancellation()
        var phase = DatabaseBrokerClientReadinessPhase.ordinary
        var phaseDeadline = addingBudget(
            readinessBudgetNanoseconds,
            to: dependencies.monotonicNanoseconds())
        var hardDeadline = UInt64.max
        let probe: DatabaseBrokerClientProbe
        do {
            probe = try await dependencies.makeProbe(phaseDeadline)
        } catch is CancellationError {
            throw CancellationError()
        } catch DatabaseBrokerClientLiveWorkerError.deadlineExceeded {
            throw phase.timeoutError
        } catch {
            guard dependencies.monotonicNanoseconds() < phaseDeadline else {
                throw phase.timeoutError
            }
            throw DatabaseBrokerAvailabilityError.unavailable
        }
        try Task.checkCancellation()
        guard dependencies.monotonicNanoseconds() < phaseDeadline else {
            throw phase.timeoutError
        }

        var transitionTurnoverDeadline: UInt64?
        var launchAttempted = false
        var backoff = initialBackoffNanoseconds

        while true {
            try Task.checkCancellation()
            let deadline = min(phaseDeadline, hardDeadline)
            let now = dependencies.monotonicNanoseconds()
            guard now < deadline else {
                throw phase.timeoutError
            }

            let outcome = probe.perform(deadline)
            try Task.checkCancellation()
            let outcomeObservedAt = dependencies.monotonicNanoseconds()
            guard outcomeObservedAt < deadline else {
                throw phase.timeoutError
            }

            switch outcome {
            case .ready:
                return
            case .notReady:
                if phase == .versionTransition {
                    phase = .ordinary
                    phaseDeadline = min(
                        addingBudget(
                            readinessBudgetNanoseconds,
                            to: outcomeObservedAt),
                        hardDeadline)
                    backoff = initialBackoffNanoseconds
                }
            case .socketMissing, .connectionRefused:
                if !launchAttempted {
                    try Task.checkCancellation()
                    let launchDeadline = min(
                        addingBudget(
                            readinessBudgetNanoseconds,
                            to: outcomeObservedAt),
                        hardDeadline)
                    guard outcomeObservedAt < launchDeadline else {
                        throw phase.timeoutError
                    }
                    do {
                        try await dependencies.launch(
                            launchDeadline,
                            launchOwnership)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch DatabaseBrokerClientLiveWorkerError.deadlineExceeded {
                        throw phase.timeoutError
                    } catch {
                        guard dependencies.monotonicNanoseconds() < launchDeadline else {
                            throw phase.timeoutError
                        }
                        throw DatabaseBrokerAvailabilityError.unavailable
                    }
                    try Task.checkCancellation()
                    let launchedAt = dependencies.monotonicNanoseconds()
                    guard launchedAt < launchDeadline else {
                        throw phase.timeoutError
                    }
                    launchAttempted = true
                    phase = .ordinary
                    phaseDeadline = launchDeadline
                    backoff = initialBackoffNanoseconds
                } else if phase == .versionTransition {
                    phase = .ordinary
                    phaseDeadline = min(
                        addingBudget(
                            readinessBudgetNanoseconds,
                            to: outcomeObservedAt),
                        hardDeadline)
                    backoff = initialBackoffNanoseconds
                }
            case .trustedVersionMismatch:
                if transitionTurnoverDeadline == nil {
                    let turnoverDeadline = addingBudget(
                        versionTransitionBudgetNanoseconds,
                        to: outcomeObservedAt)
                    transitionTurnoverDeadline = turnoverDeadline
                    hardDeadline = addingBudget(
                        readinessBudgetNanoseconds,
                        to: turnoverDeadline)
                    backoff = initialBackoffNanoseconds
                }
                phase = .versionTransition
                phaseDeadline = transitionTurnoverDeadline ?? outcomeObservedAt
            case .retryableFailure:
                break
            case .deadlineExceeded:
                throw phase.timeoutError
            case .unsafePeer:
                throw DatabaseBrokerAvailabilityError.unsafePeer
            case .outcomeUnknown:
                throw DatabaseBrokerAvailabilityError.outcomeUnknown
            case .unavailable:
                throw DatabaseBrokerAvailabilityError.unavailable
            }

            try Task.checkCancellation()
            let currentDeadline = min(phaseDeadline, hardDeadline)
            let sleepStartedAt = dependencies.monotonicNanoseconds()
            guard sleepStartedAt < currentDeadline else {
                throw phase.timeoutError
            }
            let delay = min(backoff, currentDeadline - sleepStartedAt)
            do {
                try await dependencies.sleep(delay)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DatabaseBrokerAvailabilityError.unavailable
            }
            let doubledBackoff = backoff.multipliedReportingOverflow(by: 2)
            backoff = min(
                maximumBackoffNanoseconds,
                doubledBackoff.overflow
                    ? maximumBackoffNanoseconds
                    : doubledBackoff.partialValue)
        }
    }

    private static func addingBudget(_ budget: UInt64, to time: UInt64) -> UInt64 {
        let result = time.addingReportingOverflow(budget)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

private final class DatabaseBrokerClientWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

private enum DatabaseBrokerClientReadinessPhase: Equatable {
    case ordinary
    case versionTransition

    var timeoutError: DatabaseBrokerAvailabilityError {
        switch self {
        case .ordinary:
            return .readinessTimedOut
        case .versionTransition:
            return .versionTransitionTimedOut
        }
    }
}

extension DatabaseBrokerClientCoordinatorDependencies {
    static let live = DatabaseBrokerClientCoordinatorDependencies(
        monotonicNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        sleep: { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        makeProbe: { deadlineNanoseconds in
            try await databaseBrokerClientLiveWorker.makeProbe(
                deadlineNanoseconds: deadlineNanoseconds)
        },
        launch: { deadlineNanoseconds, ownership in
            try await databaseBrokerClientLiveWorker.launch(
                deadlineNanoseconds: deadlineNanoseconds,
                ownership: ownership)
        })
}

private let databaseBrokerClientLiveDeadlineQueue = DispatchQueue(
    label: "com.edith.database.broker.client-live-deadlines",
    qos: .userInitiated)

private let databaseBrokerClientLiveWorker = DatabaseBrokerClientLiveWorker(
    dependencies: DatabaseBrokerClientLiveWorkerDependencies(
        monotonicNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        scheduleDeadline: { deadlineNanoseconds, action in
            guard deadlineNanoseconds != UInt64.max else {
                return DatabaseBrokerClientDeadlineCancellation {}
            }
            let item = DispatchWorkItem(block: action)
            databaseBrokerClientLiveDeadlineQueue.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds),
                execute: item)
            return DatabaseBrokerClientDeadlineCancellation {
                item.cancel()
            }
        },
        prepareProbe: {
            let transport = try DatabaseBrokerHealthTransport()
            return DatabaseBrokerClientProbe { deadlineNanoseconds in
                let connectedAt = DispatchTime.now().uptimeNanoseconds
                guard connectedAt < deadlineNanoseconds else {
                    return .deadlineExceeded
                }
                let remainingNanoseconds = deadlineNanoseconds - connectedAt
                let remainingMilliseconds =
                    remainingNanoseconds / 1_000_000
                    + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
                let connection: DatabaseBrokerSocketConnection
                do {
                    connection = try DatabaseBrokerSocketConnection.connect(
                        timeoutMilliseconds: Int32(
                            max(UInt64(1), min(UInt64(250), remainingMilliseconds))))
                } catch let error as DatabaseBrokerSocketError {
                    return DatabaseBrokerClientProbeOutcome.classify(error)
                } catch {
                    return .unavailable
                }
                defer { connection.close() }
                do {
                    let response = try connection.withSocketDescriptor {
                        socketDescriptor in
                        try transport.requestHealth(
                            socketDescriptor: socketDescriptor,
                            deadlineNanoseconds: deadlineNanoseconds)
                    }
                    return response.isReady
                        ? .ready(response.brokerInstanceID)
                        : .notReady(response.brokerInstanceID)
                } catch let error as DatabaseBrokerHealthTransportError {
                    return DatabaseBrokerClientProbeOutcome.classify(error)
                } catch {
                    return .unavailable
                }
            }
        },
        prepareLauncher: {
            let launcher = try DatabaseBrokerExecutableLauncher()
            return DatabaseBrokerClientLiveLauncher { lease in
                try launcher.launch(lease: lease)
            }
        }))

extension DatabaseBrokerClientProbeOutcome {
    static func classify(
        _ error: DatabaseBrokerSocketError
    ) -> DatabaseBrokerClientProbeOutcome {
        switch error {
        case .socketNotFound:
            return .socketMissing
        case .connectionRefused:
            return .connectionRefused
        case .connectionTimedOut:
            return .retryableFailure
        case .unavailable:
            return .unavailable
        case .invalidSocketPath, .invalidTimeout, .unsafeSocketEntry,
            .listenerAlreadyRunning, .existingSocketUnavailable, .notOpen:
            return .unavailable
        }
    }

    static func classify(
        _ error: DatabaseBrokerHealthTransportError
    ) -> DatabaseBrokerClientProbeOutcome {
        if error.failure == .authenticationFailed(.uniqueIdentifierMismatch) {
            return .trustedVersionMismatch
        }
        if case .authenticationFailed = error.failure {
            return .unsafePeer
        }
        return error.isReplaySafe ? .retryableFailure : .outcomeUnknown
    }
}
