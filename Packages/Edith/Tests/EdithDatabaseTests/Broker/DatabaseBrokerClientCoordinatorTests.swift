import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerClientCoordinatorTestError: Error {
    case injected
}

private actor DatabaseBrokerClientCoordinatorSleepGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for waiter in waitingForEntry {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waitingForRelease {
            waiter.resume()
        }
    }
}

private final class DatabaseBrokerClientTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64 = 0) {
        self.value = value
    }

    func read() -> UInt64 {
        lock.withLock { value }
    }

    func set(_ value: UInt64) {
        lock.withLock {
            self.value = value
        }
    }
}

private final class DatabaseBrokerClientManualDeadlineScheduler:
    @unchecked Sendable
{
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var nextIdentifier = 0
    private var scheduledActions: [Int: @Sendable () -> Void] = [:]
    private var totalScheduled = 0
    private var waiters: [Waiter] = []

    func schedule(
        _ deadlineNanoseconds: UInt64,
        action: @escaping @Sendable () -> Void
    ) -> DatabaseBrokerClientDeadlineCancellation {
        let identifier: Int
        let completedWaiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        identifier = nextIdentifier
        nextIdentifier += 1
        scheduledActions[identifier] = action
        totalScheduled += 1
        completedWaiters =
            waiters
            .filter { $0.count <= totalScheduled }
            .map(\.continuation)
        waiters.removeAll { $0.count <= totalScheduled }
        lock.unlock()
        for waiter in completedWaiters {
            waiter.resume()
        }
        return DatabaseBrokerClientDeadlineCancellation { [self] in
            cancel(identifier)
        }
    }

    func fireAll() {
        let actions = lock.withLock {
            let actions = Array(scheduledActions.values)
            scheduledActions.removeAll(keepingCapacity: false)
            return actions
        }
        for action in actions {
            action()
        }
    }

    func waitUntilScheduled(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard totalScheduled < count else { return true }
                waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func cancel(_ identifier: Int) {
        _ = lock.withLock {
            scheduledActions.removeValue(forKey: identifier)
        }
    }
}

private final class DatabaseBrokerClientBlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func enterAndBlock() {
        let continuation = lock.withLock {
            entered = true
            let continuation = entryContinuation
            entryContinuation = nil
            return continuation
        }
        continuation?.resume()
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !entered else { return true }
                entryContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class DatabaseBrokerClientLiveLaunchCapture: @unchecked Sendable {
    private struct State {
        var invocationCount = 0
        var activeCount = 0
        var maximumActiveCount = 0
        var spawnCount = 0
    }

    private let lock = NSLock()
    private let firstInvocationGate: DatabaseBrokerClientBlockingGate?
    private var state = State()

    init(firstInvocationGate: DatabaseBrokerClientBlockingGate? = nil) {
        self.firstInvocationGate = firstInvocationGate
    }

    var invocationCount: Int {
        lock.withLock { state.invocationCount }
    }

    var maximumActiveCount: Int {
        lock.withLock { state.maximumActiveCount }
    }

    var spawnCount: Int {
        lock.withLock { state.spawnCount }
    }

    func launcher() -> DatabaseBrokerClientLiveLauncher {
        DatabaseBrokerClientLiveLauncher { [self] lease in
            let invocation = beginInvocation()
            defer { endInvocation() }
            if invocation == 1 {
                firstInvocationGate?.enterAndBlock()
            }
            try lease.commit {
                recordSpawn()
            }
        }
    }

    private func beginInvocation() -> Int {
        lock.withLock {
            state.invocationCount += 1
            state.activeCount += 1
            state.maximumActiveCount = max(
                state.maximumActiveCount,
                state.activeCount)
            return state.invocationCount
        }
    }

    private func endInvocation() {
        lock.withLock {
            state.activeCount -= 1
        }
    }

    private func recordSpawn() {
        lock.withLock {
            state.spawnCount += 1
        }
    }
}

private final class DatabaseBrokerClientCoordinatorStub: @unchecked Sendable {
    private struct State {
        var now: UInt64 = 0
        var outcomes: [DatabaseBrokerClientProbeOutcome]
        var defaultOutcome: DatabaseBrokerClientProbeOutcome
        var makeProbeCount = 0
        var probeCount = 0
        var launchCount = 0
        var sleeps: [UInt64] = []
    }

    private let lock = NSLock()
    private var state: State
    private let sleepOverride: (@Sendable (UInt64) async throws -> Void)?
    private let makeProbeAdvanceNanoseconds: UInt64
    private let probeAdvanceNanoseconds: UInt64
    private let launchAdvanceNanoseconds: UInt64
    var failProbeCreation = false
    var failLaunch = false

    init(
        outcomes: [DatabaseBrokerClientProbeOutcome],
        defaultOutcome: DatabaseBrokerClientProbeOutcome = .unavailable,
        sleepOverride: (@Sendable (UInt64) async throws -> Void)? = nil,
        makeProbeAdvanceNanoseconds: UInt64 = 0,
        probeAdvanceNanoseconds: UInt64 = 0,
        launchAdvanceNanoseconds: UInt64 = 0
    ) {
        state = State(
            outcomes: outcomes,
            defaultOutcome: defaultOutcome)
        self.sleepOverride = sleepOverride
        self.makeProbeAdvanceNanoseconds = makeProbeAdvanceNanoseconds
        self.probeAdvanceNanoseconds = probeAdvanceNanoseconds
        self.launchAdvanceNanoseconds = launchAdvanceNanoseconds
    }

    var now: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return state.now
    }

    var makeProbeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.makeProbeCount
    }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.probeCount
    }

    var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.launchCount
    }

    var sleeps: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return state.sleeps
    }

    func dependencies() -> DatabaseBrokerClientCoordinatorDependencies {
        DatabaseBrokerClientCoordinatorDependencies(
            monotonicNanoseconds: { self.now },
            sleep: { nanoseconds in
                if let sleepOverride = self.sleepOverride {
                    try await sleepOverride(nanoseconds)
                }
                self.recordSleep(nanoseconds)
            },
            makeProbe: { _ in
                try self.makeProbe()
            },
            launch: { _, _ in
                try self.launch()
            })
    }

    private func makeProbe() throws -> DatabaseBrokerClientProbe {
        let shouldFail = lock.withLock {
            state.makeProbeCount += 1
            state.now += makeProbeAdvanceNanoseconds
            return failProbeCreation
        }
        if shouldFail {
            throw DatabaseBrokerClientCoordinatorTestError.injected
        }
        return DatabaseBrokerClientProbe { _ in
            self.nextOutcome()
        }
    }

    private func launch() throws {
        let shouldFail = lock.withLock {
            state.launchCount += 1
            state.now += launchAdvanceNanoseconds
            return failLaunch
        }
        if shouldFail {
            throw DatabaseBrokerClientCoordinatorTestError.injected
        }
    }

    private func nextOutcome() -> DatabaseBrokerClientProbeOutcome {
        lock.lock()
        defer { lock.unlock() }
        state.probeCount += 1
        state.now += probeAdvanceNanoseconds
        guard !state.outcomes.isEmpty else {
            return state.defaultOutcome
        }
        return state.outcomes.removeFirst()
    }

    private func recordSleep(_ nanoseconds: UInt64) {
        lock.lock()
        state.sleeps.append(nanoseconds)
        state.now += nanoseconds
        lock.unlock()
    }
}

@Suite struct DatabaseBrokerClientCoordinatorTests {
    private static let firstInstance = UUID(
        uuidString: "5A8D55D0-D2E4-433D-B710-DC8EB94BEB4A")!
    private static let secondInstance = UUID(
        uuidString: "E89D0114-113C-4B66-BDD8-BD87041CF07F")!

    @Test func existingReadyBrokerDoesNotLaunch() async throws {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.ready(Self.firstInstance)])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        try await coordinator.ensureReady()

        #expect(stub.makeProbeCount == 1)
        #expect(stub.probeCount == 1)
        #expect(stub.launchCount == 0)
        #expect(stub.sleeps.isEmpty)
    }

    @Test func concurrentCallersShareOneLaunch() async throws {
        let gate = DatabaseBrokerClientCoordinatorSleepGate()
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.socketMissing, .ready(Self.firstInstance)],
            sleepOverride: { _ in await gate.suspend() })
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())
        let callers = (0..<100).map { _ in
            Task {
                try await coordinator.ensureReady()
            }
        }

        await gate.waitUntilEntered()
        while await coordinator.pendingWaiterCount() < 100 {
            await Task.yield()
        }
        let waiterCount = await coordinator.pendingWaiterCount()
        #expect(waiterCount == 100)
        #expect(stub.launchCount == 1)
        await gate.release()
        for caller in callers {
            try await caller.value
        }

        #expect(stub.launchCount == 1)
    }

    @Test func falseReadinessNeverRelaunchesAndUsesOneDeadline() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .notReady(Self.firstInstance),
                .notReady(Self.secondInstance),
            ],
            defaultOutcome: .notReady(Self.firstInstance))
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await coordinator.ensureReady()
        }

        #expect(stub.launchCount == 0)
        #expect(stub.now == DatabaseBrokerClientCoordinator.readinessBudgetNanoseconds)
        #expect(stub.probeCount > 2)
    }

    @Test(arguments: [
        DatabaseBrokerClientProbeOutcome.socketMissing,
        DatabaseBrokerClientProbeOutcome.connectionRefused,
    ])
    func absentSocketLaunchesOnlyOnce(
        initialOutcome: DatabaseBrokerClientProbeOutcome
    ) async throws {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                initialOutcome,
                .socketMissing,
                .ready(Self.firstInstance),
            ])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        try await coordinator.ensureReady()

        #expect(stub.launchCount == 1)
        #expect(stub.probeCount == 3)
    }

    @Test func replaySafeFailureRetriesWithoutLaunching() async throws {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .retryableFailure,
                .ready(Self.firstInstance),
            ])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        try await coordinator.ensureReady()

        #expect(stub.launchCount == 0)
        #expect(stub.probeCount == 2)
    }

    @Test func outcomeUnknownDoesNotRetry() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .outcomeUnknown,
                .ready(Self.firstInstance),
            ])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.outcomeUnknown) {
            try await coordinator.ensureReady()
        }

        #expect(stub.probeCount == 1)
        #expect(stub.launchCount == 0)
    }

    @Test func oneCancelledWaiterDoesNotCancelSharedReadiness() async throws {
        let gate = DatabaseBrokerClientCoordinatorSleepGate()
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.socketMissing, .ready(Self.firstInstance)],
            sleepOverride: { _ in await gate.suspend() })
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())
        let cancelled = Task {
            try await coordinator.ensureReady()
        }

        await gate.waitUntilEntered()
        let survivor = Task {
            try await coordinator.ensureReady()
        }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        await gate.release()
        try await survivor.value

        #expect(stub.launchCount == 1)
        #expect(stub.probeCount == 2)
    }

    @Test func trustedVersionMismatchWaitsForTurnoverThenLaunches() async throws {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .trustedVersionMismatch,
                .trustedVersionMismatch,
                .socketMissing,
                .ready(Self.secondInstance),
            ])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        try await coordinator.ensureReady()

        #expect(stub.launchCount == 1)
        #expect(stub.probeCount == 4)
    }

    @Test func trustedVersionMismatchHasDedicatedDeadline() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.trustedVersionMismatch],
            defaultOutcome: .trustedVersionMismatch)
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(
            throws: DatabaseBrokerAvailabilityError.versionTransitionTimedOut
        ) {
            try await coordinator.ensureReady()
        }

        #expect(stub.launchCount == 0)
        #expect(stub.now == DatabaseBrokerClientCoordinator.versionTransitionBudgetNanoseconds)
    }

    @Test func unsafePeerNeverLaunches() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.unsafePeer])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.unsafePeer) {
            try await coordinator.ensureReady()
        }

        #expect(stub.probeCount == 1)
        #expect(stub.launchCount == 0)
    }

    @Test func failedProbeConstructionIsUnavailable() async {
        let stub = DatabaseBrokerClientCoordinatorStub(outcomes: [])
        stub.failProbeCreation = true
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.unavailable) {
            try await coordinator.ensureReady()
        }

        #expect(stub.makeProbeCount == 1)
        #expect(stub.probeCount == 0)
        #expect(stub.launchCount == 0)
    }

    @Test func failedLaunchIsUnavailableAndNotRetried() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.socketMissing])
        stub.failLaunch = true
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.unavailable) {
            try await coordinator.ensureReady()
        }

        #expect(stub.launchCount == 1)
        #expect(stub.probeCount == 1)
    }

    @Test func callerCancelledBeforeEntryPerformsNoReadinessWork() async {
        let entryGate = DatabaseBrokerClientCoordinatorSleepGate()
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.ready(Self.firstInstance)])
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())
        let caller = Task {
            await entryGate.suspend()
            try await coordinator.ensureReady()
        }

        await entryGate.waitUntilEntered()
        caller.cancel()
        await entryGate.release()

        await #expect(throws: CancellationError.self) {
            try await caller.value
        }
        #expect(stub.makeProbeCount == 0)
        #expect(stub.probeCount == 0)
        #expect(stub.launchCount == 0)
    }

    @Test func lastCancelledWaiterRetiresGeneration() async throws {
        let sleepGate = DatabaseBrokerClientCoordinatorSleepGate()
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .retryableFailure,
                .ready(Self.firstInstance),
            ],
            sleepOverride: { _ in await sleepGate.suspend() })
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())
        let first = Task {
            try await coordinator.ensureReady()
        }
        let second = Task {
            try await coordinator.ensureReady()
        }

        await sleepGate.waitUntilEntered()
        while await coordinator.pendingWaiterCount() < 2 {
            await Task.yield()
        }
        first.cancel()
        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        let pendingWaiterCount = await coordinator.pendingWaiterCount()
        #expect(pendingWaiterCount == 0)
        #expect(stub.makeProbeCount == 1)
        #expect(stub.probeCount == 1)
        #expect(stub.launchCount == 0)

        await sleepGate.release()
        for _ in 0..<10 {
            await Task.yield()
        }
        try await coordinator.ensureReady()

        #expect(stub.makeProbeCount == 2)
        #expect(stub.probeCount == 2)
        #expect(stub.launchCount == 0)
    }

    @Test func cancellationWinsCompletionRace() async {
        for _ in 0..<20 {
            let sleepGate = DatabaseBrokerClientCoordinatorSleepGate()
            let stub = DatabaseBrokerClientCoordinatorStub(
                outcomes: [
                    .retryableFailure,
                    .ready(Self.firstInstance),
                ],
                sleepOverride: { _ in await sleepGate.suspend() })
            let coordinator = DatabaseBrokerClientCoordinator(
                dependencies: stub.dependencies())
            let caller = Task {
                try await coordinator.ensureReady()
            }

            await sleepGate.waitUntilEntered()
            caller.cancel()
            await sleepGate.release()

            await #expect(throws: CancellationError.self) {
                try await caller.value
            }
        }
    }

    @Test func probeConstructionConsumesTheAbsoluteDeadline() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.ready(Self.firstInstance)],
            makeProbeAdvanceNanoseconds:
                DatabaseBrokerClientCoordinator.readinessBudgetNanoseconds)
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await coordinator.ensureReady()
        }

        #expect(stub.probeCount == 0)
        #expect(stub.launchCount == 0)
    }

    @Test func oneProbeCannotOutrunTheAbsoluteDeadline() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.ready(Self.firstInstance)],
            probeAdvanceNanoseconds:
                DatabaseBrokerClientCoordinator.readinessBudgetNanoseconds)
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await coordinator.ensureReady()
        }

        #expect(stub.probeCount == 1)
        #expect(stub.launchCount == 0)
    }

    @Test func launchTimeIsInsideThePostLaunchDeadline() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [.socketMissing],
            launchAdvanceNanoseconds:
                DatabaseBrokerClientCoordinator.readinessBudgetNanoseconds)
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await coordinator.ensureReady()
        }

        #expect(stub.probeCount == 1)
        #expect(stub.launchCount == 1)
    }

    @Test func launchedBrokerCanRemainNotReadyWithoutRelaunch() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .socketMissing,
                .notReady(Self.firstInstance),
            ],
            defaultOutcome: .notReady(Self.firstInstance))
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await coordinator.ensureReady()
        }

        #expect(stub.launchCount == 1)
    }

    @Test func currentNotReadyBrokerEndsVersionTurnoverWithoutLaunching() async {
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: [
                .trustedVersionMismatch,
                .notReady(Self.secondInstance),
            ],
            defaultOutcome: .notReady(Self.secondInstance))
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await coordinator.ensureReady()
        }

        #expect(stub.launchCount == 0)
    }

    @Test func alternatingVersionStatesCannotRenewTheHardDeadline() async {
        var outcomes: [DatabaseBrokerClientProbeOutcome] = []
        for _ in 0..<100 {
            outcomes.append(.trustedVersionMismatch)
            outcomes.append(.notReady(Self.secondInstance))
            outcomes.append(.socketMissing)
        }
        let stub = DatabaseBrokerClientCoordinatorStub(
            outcomes: outcomes,
            defaultOutcome: .trustedVersionMismatch)
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: stub.dependencies())

        await #expect(throws: DatabaseBrokerAvailabilityError.self) {
            try await coordinator.ensureReady()
        }

        let maximumDuration =
            DatabaseBrokerClientCoordinator.versionTransitionBudgetNanoseconds
            + DatabaseBrokerClientCoordinator.readinessBudgetNanoseconds
        #expect(stub.now <= maximumDuration)
        #expect(stub.launchCount == 1)
    }

    @Test func blockedProbePreparationReturnsAtTheDeadline() async {
        let clock = DatabaseBrokerClientTestClock()
        let scheduler = DatabaseBrokerClientManualDeadlineScheduler()
        let preparationGate = DatabaseBrokerClientBlockingGate()
        let worker = DatabaseBrokerClientLiveWorker(
            dependencies: DatabaseBrokerClientLiveWorkerDependencies(
                monotonicNanoseconds: { clock.read() },
                scheduleDeadline: { deadlineNanoseconds, action in
                    scheduler.schedule(deadlineNanoseconds, action: action)
                },
                prepareProbe: {
                    preparationGate.enterAndBlock()
                    return DatabaseBrokerClientProbe { _ in
                        .ready(Self.firstInstance)
                    }
                },
                prepareLauncher: {
                    DatabaseBrokerClientLiveLaunchCapture().launcher()
                }))
        let coordinator = DatabaseBrokerClientCoordinator(
            dependencies: DatabaseBrokerClientCoordinatorDependencies(
                monotonicNanoseconds: { clock.read() },
                sleep: { _ in },
                makeProbe: { deadlineNanoseconds in
                    try await worker.makeProbe(
                        deadlineNanoseconds: deadlineNanoseconds)
                },
                launch: { deadlineNanoseconds, ownership in
                    try await worker.launch(
                        deadlineNanoseconds: deadlineNanoseconds,
                        ownership: ownership)
                }))
        let caller = Task {
            try await coordinator.ensureReady()
        }

        await preparationGate.waitUntilEntered()
        scheduler.fireAll()

        await #expect(throws: DatabaseBrokerAvailabilityError.readinessTimedOut) {
            try await caller.value
        }
        preparationGate.release()
    }

    @Test func replacementLaunchWaitsForCancelledLaunchWork() async throws {
        let clock = DatabaseBrokerClientTestClock()
        let scheduler = DatabaseBrokerClientManualDeadlineScheduler()
        let launchGate = DatabaseBrokerClientBlockingGate()
        let launchCapture = DatabaseBrokerClientLiveLaunchCapture(
            firstInvocationGate: launchGate)
        let worker = DatabaseBrokerClientLiveWorker(
            dependencies: DatabaseBrokerClientLiveWorkerDependencies(
                monotonicNanoseconds: { clock.read() },
                scheduleDeadline: { deadlineNanoseconds, action in
                    scheduler.schedule(deadlineNanoseconds, action: action)
                },
                prepareProbe: {
                    DatabaseBrokerClientProbe { _ in
                        .ready(Self.firstInstance)
                    }
                },
                prepareLauncher: { launchCapture.launcher() }))
        let first = Task {
            try await worker.launch(
                deadlineNanoseconds: 100,
                ownership: DatabaseBrokerClientLaunchOwnership())
        }

        await launchGate.waitUntilEntered()
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }

        let second = Task {
            try await worker.launch(
                deadlineNanoseconds: 200,
                ownership: DatabaseBrokerClientLaunchOwnership())
        }
        await scheduler.waitUntilScheduled(2)

        #expect(launchCapture.invocationCount == 1)
        #expect(launchCapture.maximumActiveCount == 1)
        #expect(launchCapture.spawnCount == 0)

        launchGate.release()
        try await second.value

        #expect(launchCapture.invocationCount == 2)
        #expect(launchCapture.maximumActiveCount == 1)
        #expect(launchCapture.spawnCount == 1)
    }

    @Test func committedSpawnIsOwnedThroughItsReadinessWindow() async throws {
        let clock = DatabaseBrokerClientTestClock()
        let scheduler = DatabaseBrokerClientManualDeadlineScheduler()
        let launchCapture = DatabaseBrokerClientLiveLaunchCapture()
        let worker = DatabaseBrokerClientLiveWorker(
            dependencies: DatabaseBrokerClientLiveWorkerDependencies(
                monotonicNanoseconds: { clock.read() },
                scheduleDeadline: { deadlineNanoseconds, action in
                    scheduler.schedule(deadlineNanoseconds, action: action)
                },
                prepareProbe: {
                    DatabaseBrokerClientProbe { _ in
                        .ready(Self.firstInstance)
                    }
                },
                prepareLauncher: { launchCapture.launcher() }))

        try await worker.launch(
            deadlineNanoseconds: 100,
            ownership: DatabaseBrokerClientLaunchOwnership())
        try await worker.launch(
            deadlineNanoseconds: 200,
            ownership: DatabaseBrokerClientLaunchOwnership())

        #expect(launchCapture.invocationCount == 1)
        #expect(launchCapture.spawnCount == 1)

        clock.set(100)
        try await worker.launch(
            deadlineNanoseconds: 300,
            ownership: DatabaseBrokerClientLaunchOwnership())

        #expect(launchCapture.invocationCount == 2)
        #expect(launchCapture.spawnCount == 2)
    }

    @Test func classifiesLiveSocketFailures() {
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(.socketNotFound)
                == .socketMissing)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(.connectionRefused)
                == .connectionRefused)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(.connectionTimedOut)
                == .retryableFailure)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(.unavailable)
                == .unavailable)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(.invalidSocketPath)
                == .unavailable)
    }

    @Test func classifiesLiveTransportFailures() {
        let mismatch = DatabaseBrokerHealthTransportError(
            failure: .authenticationFailed(.uniqueIdentifierMismatch),
            bytesWritten: 0)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(mismatch)
                == .trustedVersionMismatch)

        let authenticationFailures: [DatabaseBrokerPeerAuthenticationError] = [
            .invalidSocketDescriptor,
            .peerUserIdentifierUnavailable,
            .peerUserIdentifierMismatch(expected: 501, actual: 502),
            .peerAuditTokenUnavailable,
            .malformedPeerAuditToken,
            .peerCodeUnavailable,
            .peerStaticCodeUnavailable,
            .currentCodeUnavailable,
            .currentStaticCodeUnavailable,
            .currentDesignatedRequirementUnavailable,
            .currentCodeInvalid,
            .peerCodeInvalid,
            .currentUniqueIdentifierUnavailable,
            .peerUniqueIdentifierUnavailable,
        ]
        for failure in authenticationFailures {
            let error = DatabaseBrokerHealthTransportError(
                failure: .authenticationFailed(failure),
                bytesWritten: 0)
            #expect(
                DatabaseBrokerClientProbeOutcome.classify(error)
                    == .unsafePeer)
        }

        let replaySafe = DatabaseBrokerHealthTransportError(
            failure: .ioFailure,
            bytesWritten: 0)
        let outcomeUnknown = DatabaseBrokerHealthTransportError(
            failure: .ioFailure,
            bytesWritten: 1)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(replaySafe)
                == .retryableFailure)
        #expect(
            DatabaseBrokerClientProbeOutcome.classify(outcomeUnknown)
                == .outcomeUnknown)
    }
}
