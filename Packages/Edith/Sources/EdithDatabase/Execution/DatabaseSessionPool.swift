import Foundation

struct DatabaseSessionGeneration: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        rawValue = UUID()
    }
}

struct DatabaseSessionLease: Sendable {
    let generation: DatabaseSessionGeneration
    let definition: DatabaseConnectionDefinition
    let session: any DatabaseAdapterSession
    let report: DatabaseCapabilityReport
    let reportSource: DatabaseCapabilityReportSource
}

struct DatabaseSessionTestResult: Sendable {
    let generation: DatabaseSessionGeneration
    let definition: DatabaseConnectionDefinition
    let productIdentity: DatabaseProductIdentity
    let report: DatabaseCapabilityReport
}

struct DatabaseSessionPoolDiagnostics: Equatable, Sendable {
    let connectWaiters: Int
    let refreshWaiters: Int
    let completionObservers: Int
    let sharedCancellationObservers: Int
    let activeTasks: Int
    let cleanupTasks: Int
}

private actor DatabaseSessionDisconnector {
    private var didDisconnect = false

    func disconnect(_ session: any DatabaseAdapterSession) async {
        guard !didDisconnect else { return }
        didDisconnect = true
        await session.disconnect()
    }
}

private enum DatabaseSessionWaitOutcome<Value: Sendable>: Sendable {
    case completed(Result<Value, DatabaseAdapterFailure>)
    case callerCancelled(DatabaseAdapterCancellationReason)
    case sharedCancelled(DatabaseAdapterCancellationReason)
}

private actor DatabaseSessionCompletionBroadcaster<Value: Sendable> {
    typealias Output = Result<Value, DatabaseAdapterFailure>

    private var result: Output?
    private var isRetired = false
    private var observers: [UUID: AsyncStream<Output>.Continuation] = [:]

    func events() -> AsyncStream<Output> {
        let identifier = UUID()
        let pair = AsyncStream<Output>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if isRetired {
            pair.continuation.finish()
        } else if let result {
            pair.continuation.yield(result)
            pair.continuation.finish()
        } else {
            pair.continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeObserver(identifier)
                }
            }
            observers[identifier] = pair.continuation
        }
        return pair.stream
    }

    func resolve(_ result: Output) -> Output? {
        guard !isRetired else { return result }
        guard self.result == nil else { return nil }
        self.result = result
        let pending = observers.values
        observers.removeAll()
        for observer in pending {
            observer.yield(result)
            observer.finish()
        }
        return nil
    }

    func retire() -> Output? {
        guard !isRetired else { return nil }
        isRetired = true
        let completed = result
        result = nil
        let pending = observers.values
        observers.removeAll()
        for observer in pending {
            observer.finish()
        }
        return completed
    }

    func observerCount() -> Int {
        observers.count
    }

    private func removeObserver(_ identifier: UUID) {
        observers.removeValue(forKey: identifier)
    }
}

private struct DatabaseSessionReady: Sendable {
    let generation: DatabaseSessionGeneration
    let definition: DatabaseConnectionDefinition
    let session: any DatabaseAdapterSession
    let report: DatabaseCapabilityReport
    let redactor: DatabaseSecretRedactor
    let disconnector: DatabaseSessionDisconnector

    init(
        generation: DatabaseSessionGeneration,
        definition: DatabaseConnectionDefinition,
        session: any DatabaseAdapterSession,
        report: DatabaseCapabilityReport,
        redactor: DatabaseSecretRedactor,
        disconnector: DatabaseSessionDisconnector = DatabaseSessionDisconnector()
    ) {
        self.generation = generation
        self.definition = definition
        self.session = session
        self.report = report
        self.redactor = redactor
        self.disconnector = disconnector
    }

    func lease(source: DatabaseCapabilityReportSource) -> DatabaseSessionLease {
        DatabaseSessionLease(
            generation: generation,
            definition: definition,
            session: session,
            report: report,
            reportSource: source)
    }

    func replacingReport(_ report: DatabaseCapabilityReport) -> DatabaseSessionReady {
        DatabaseSessionReady(
            generation: generation,
            definition: definition,
            session: session,
            report: report,
            redactor: redactor,
            disconnector: disconnector)
    }

    func disconnect() async {
        await disconnector.disconnect(session)
    }
}

private struct DatabaseSessionConnectAttempt: Sendable {
    let generation: DatabaseSessionGeneration
    let definition: DatabaseConnectionDefinition
    let cancellation: DatabaseAdapterCancellationSignal
    let completion: DatabaseSessionCompletionBroadcaster<DatabaseSessionReady>
    let task: Task<Result<DatabaseSessionReady, DatabaseAdapterFailure>, Never>
}

private struct DatabaseSessionRefreshAttempt: Sendable {
    let id: UUID
    let generation: DatabaseSessionGeneration
    let definition: DatabaseConnectionDefinition
    let sessionID: DatabaseAdapterSessionID
    let cancellation: DatabaseAdapterCancellationSignal
    let completion: DatabaseSessionCompletionBroadcaster<DatabaseCapabilityReport>
    let task: Task<Result<DatabaseCapabilityReport, DatabaseAdapterFailure>, Never>
}

private struct DatabaseSessionConnectWaiters: Sendable {
    var count: Int
    var deliveredLease: Bool
    let attempt: DatabaseSessionConnectAttempt
}

private struct DatabaseSessionRefreshWaiters: Sendable {
    var count: Int
    let attempt: DatabaseSessionRefreshAttempt
}

private enum DatabaseSessionPoolEntry: Sendable {
    case connecting(DatabaseSessionConnectAttempt)
    case ready(DatabaseSessionReady)
    case refreshing(DatabaseSessionReady, DatabaseSessionRefreshAttempt)

    var generation: DatabaseSessionGeneration {
        switch self {
        case let .connecting(attempt):
            attempt.generation
        case let .ready(ready), let .refreshing(ready, _):
            ready.generation
        }
    }

    var definition: DatabaseConnectionDefinition {
        switch self {
        case let .connecting(attempt):
            attempt.definition
        case let .ready(ready), let .refreshing(ready, _):
            ready.definition
        }
    }
}

actor DatabaseSessionPool {
    private static let maximumTrackedTasks = 64

    private let registry: DatabaseAdapterRegistry
    private let secretStore: any DatabaseSecretStore
    private let currentDate: @Sendable () -> Date
    private var entries: [DatabaseConnectionID: DatabaseSessionPoolEntry] = [:]
    private var connectWaiters: [DatabaseSessionGeneration: DatabaseSessionConnectWaiters] = [:]
    private var refreshWaiters: [UUID: DatabaseSessionRefreshWaiters] = [:]
    private var trackedTasks: [UUID: Bool] = [:]

    init(
        registry: DatabaseAdapterRegistry,
        secretStore: any DatabaseSecretStore,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.secretStore = secretStore
        self.currentDate = currentDate
    }

    func lease(
        for definition: DatabaseConnectionDefinition,
        resolution: DatabaseCapabilityResolution = .cachedOrDiscover,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseSessionLease {
        while true {
            try await checkCallerContext(context)
            guard let entry = entries[definition.id] else {
                let attempt = try startConnect(definition: definition)
                entries[definition.id] = .connecting(attempt)
                connectWaiters[attempt.generation] = DatabaseSessionConnectWaiters(
                    count: 1,
                    deliveredLease: false,
                    attempt: attempt)
                return try await finishConnect(
                    attempt,
                    context: context)
            }
            guard entry.definition == definition else {
                entries.removeValue(forKey: definition.id)
                await dispose(entry)
                continue
            }
            switch entry {
            case let .connecting(attempt):
                guard var waiters = connectWaiters[attempt.generation] else {
                    entries.removeValue(forKey: definition.id)
                    await dispose(entry)
                    continue
                }
                waiters.count += 1
                connectWaiters[attempt.generation] = waiters
                return try await finishConnect(
                    attempt,
                    context: context)
            case let .ready(ready):
                guard await validateCached(ready) else {
                    if let removed = removeOwnedEntry(
                        ready.generation,
                        connectionID: definition.id)
                    {
                        await dispose(removed)
                    }
                    continue
                }
                guard
                    owns(
                        ready.generation,
                        sessionID: ready.session.id,
                        connectionID: definition.id)
                else {
                    continue
                }
                if resolution == .refresh || isExpired(ready.report) {
                    let attempt = try startRefresh(ready: ready)
                    entries[definition.id] = .refreshing(ready, attempt)
                    refreshWaiters[attempt.id] = DatabaseSessionRefreshWaiters(
                        count: 1,
                        attempt: attempt)
                    return try await finishRefresh(
                        ready: ready,
                        attempt: attempt,
                        context: context)
                }
                return try await validatedLease(
                    generation: ready.generation,
                    sessionID: ready.session.id,
                    connectionID: definition.id,
                    source: .cached,
                    context: context)
            case let .refreshing(ready, attempt):
                guard var waiters = refreshWaiters[attempt.id] else {
                    entries[definition.id] = .ready(ready)
                    continue
                }
                waiters.count += 1
                refreshWaiters[attempt.id] = waiters
                return try await finishRefresh(
                    ready: ready,
                    attempt: attempt,
                    context: context)
            }
        }
    }

    func testConnection(
        definition: DatabaseConnectionDefinition,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseSessionTestResult {
        try await checkCallerContext(context)
        let generation = DatabaseSessionGeneration()
        try reserveTask(generation.rawValue)
        let completion = DatabaseSessionCompletionBroadcaster<DatabaseSessionReady>()
        let task = Task {
            let result = await Self.establish(
                generation: generation,
                definition: definition,
                registry: registry,
                secretStore: secretStore,
                currentDate: currentDate,
                context: context)
            if let retired = await completion.resolve(result),
                case let .success(ready) = retired
            {
                await ready.disconnect()
            }
            self.finishTask(generation.rawValue)
            return result
        }
        let outcome = await waitShared(
            completion: completion,
            context: context,
            sharedCancellation: context.cancellation)
        guard case let .completed(result) = outcome else {
            let reason: DatabaseAdapterCancellationReason
            switch outcome {
            case let .callerCancelled(cancellation), let .sharedCancelled(cancellation):
                reason = cancellation
            case .completed:
                throw .cancelled
            }
            task.cancel()
            markTaskRetired(generation.rawValue)
            await context.cancellation.cancel(reason)
            if let completed = await completion.retire(),
                case let .success(ready) = completed
            {
                await ready.disconnect()
            }
            throw .cancelled
        }
        switch result {
        case let .success(ready):
            _ = await completion.retire()
            await ready.disconnect()
            try await checkCallerContext(context)
            return DatabaseSessionTestResult(
                generation: generation,
                definition: definition,
                productIdentity: ready.report.productIdentity,
                report: ready.report)
        case let .failure(failure):
            _ = await completion.retire()
            throw failure
        }
    }

    func disconnect(connectionID: DatabaseConnectionID) async -> Bool {
        guard let entry = entries.removeValue(forKey: connectionID) else { return false }
        await dispose(entry)
        return true
    }

    func disconnectAll() async {
        let disconnected = Array(entries.values)
        entries.removeAll(keepingCapacity: false)
        for entry in disconnected {
            await dispose(entry)
        }
    }

    func diagnostics() async -> DatabaseSessionPoolDiagnostics {
        let connections = Array(connectWaiters.values)
        let refreshes = Array(refreshWaiters.values)
        var observerCount = 0
        var cancellationObserverCount = 0
        for waiters in connections {
            observerCount += await waiters.attempt.completion.observerCount()
            cancellationObserverCount +=
                await waiters.attempt.cancellation.registeredEventStreamCount()
        }
        for waiters in refreshes {
            observerCount += await waiters.attempt.completion.observerCount()
            cancellationObserverCount +=
                await waiters.attempt.cancellation.registeredEventStreamCount()
        }
        return DatabaseSessionPoolDiagnostics(
            connectWaiters: connections.reduce(0) { $0 + $1.count },
            refreshWaiters: refreshes.reduce(0) { $0 + $1.count },
            completionObservers: observerCount,
            sharedCancellationObservers: cancellationObserverCount,
            activeTasks: trackedTasks.values.filter { !$0 }.count,
            cleanupTasks: trackedTasks.values.filter { $0 }.count)
    }

    private func startConnect(
        definition: DatabaseConnectionDefinition
    ) throws(DatabaseAdapterFailure) -> DatabaseSessionConnectAttempt {
        let generation = DatabaseSessionGeneration()
        try reserveTask(generation.rawValue)
        let cancellation = DatabaseAdapterCancellationSignal()
        let completion = DatabaseSessionCompletionBroadcaster<DatabaseSessionReady>()
        let sharedContext = DatabaseAdapterConnectionContext(
            operation: DatabaseOperationContext(),
            cancellation: cancellation)
        let task = Task {
            let result = await Self.establish(
                generation: generation,
                definition: definition,
                registry: registry,
                secretStore: secretStore,
                currentDate: currentDate,
                context: sharedContext)
            if let retired = await completion.resolve(result),
                case let .success(ready) = retired
            {
                await ready.disconnect()
            }
            self.finishTask(generation.rawValue)
            return result
        }
        return DatabaseSessionConnectAttempt(
            generation: generation,
            definition: definition,
            cancellation: cancellation,
            completion: completion,
            task: task)
    }

    private func finishConnect(
        _ attempt: DatabaseSessionConnectAttempt,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseSessionLease {
        let outcome = await waitShared(
            completion: attempt.completion,
            context: context,
            sharedCancellation: attempt.cancellation)
        guard case let .completed(result) = outcome else {
            let reason: DatabaseAdapterCancellationReason
            switch outcome {
            case let .callerCancelled(cancellation), let .sharedCancelled(cancellation):
                reason = cancellation
            case .completed:
                throw .cancelled
            }
            await finishConnectWaiter(
                attempt,
                deliveredLease: false,
                cancellationReason: reason)
            throw .cancelled
        }
        switch result {
        case let .failure(failure):
            _ = removeOwnedEntry(
                attempt.generation,
                connectionID: attempt.definition.id)
            let reason = await callerCancellationReason(context, failure: failure)
            await finishConnectWaiter(
                attempt,
                deliveredLease: false,
                cancellationReason: reason)
            if reason != nil {
                throw .cancelled
            }
            throw failure
        case let .success(established):
            let ready: DatabaseSessionReady
            switch entries[attempt.definition.id] {
            case let .connecting(current) where current.generation == attempt.generation:
                entries[attempt.definition.id] = .ready(established)
                ready = established
            case let .ready(current)
            where current.generation == attempt.generation
                && current.session.id == established.session.id:
                ready = current
            case let .refreshing(current, _)
            where current.generation == attempt.generation
                && current.session.id == established.session.id:
                ready = current
            default:
                await established.disconnect()
                await finishConnectWaiter(
                    attempt,
                    deliveredLease: false,
                    cancellationReason: nil)
                throw .contractViolation(.staleSession)
            }
            do {
                let lease: DatabaseSessionLease
                if isExpired(ready.report) {
                    lease = try await self.lease(
                        for: ready.definition,
                        resolution: .refresh,
                        context: context)
                } else {
                    lease = try await validatedLease(
                        generation: ready.generation,
                        sessionID: ready.session.id,
                        connectionID: ready.definition.id,
                        source: .discovered,
                        context: context)
                }
                await finishConnectWaiter(
                    attempt,
                    deliveredLease: true,
                    cancellationReason: nil)
                return lease
            } catch let failure {
                let reason = await callerCancellationReason(context, failure: failure)
                await finishConnectWaiter(
                    attempt,
                    deliveredLease: false,
                    cancellationReason: reason)
                throw failure
            }
        }
    }

    private func startRefresh(
        ready: DatabaseSessionReady
    ) throws(DatabaseAdapterFailure) -> DatabaseSessionRefreshAttempt {
        let identifier = UUID()
        try reserveTask(identifier)
        let cancellation = DatabaseAdapterCancellationSignal()
        let completion = DatabaseSessionCompletionBroadcaster<DatabaseCapabilityReport>()
        let sharedContext = DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(),
            cancellation: cancellation)
        let task = Task {
            let result = await Self.refresh(
                ready: ready,
                currentDate: currentDate,
                context: sharedContext)
            _ = await completion.resolve(result)
            self.finishTask(identifier)
            return result
        }
        return DatabaseSessionRefreshAttempt(
            id: identifier,
            generation: ready.generation,
            definition: ready.definition,
            sessionID: ready.session.id,
            cancellation: cancellation,
            completion: completion,
            task: task)
    }

    private func finishRefresh(
        ready: DatabaseSessionReady,
        attempt: DatabaseSessionRefreshAttempt,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseSessionLease {
        let outcome = await waitShared(
            completion: attempt.completion,
            context: context,
            sharedCancellation: attempt.cancellation)
        guard case let .completed(result) = outcome else {
            let reason: DatabaseAdapterCancellationReason
            switch outcome {
            case let .callerCancelled(cancellation), let .sharedCancelled(cancellation):
                reason = cancellation
            case .completed:
                throw .cancelled
            }
            await finishRefreshWaiter(
                attempt: attempt,
                cancellationReason: reason)
            throw .cancelled
        }
        switch result {
        case let .failure(failure):
            _ = removeOwnedEntry(
                attempt.generation,
                connectionID: attempt.definition.id)
            await ready.disconnect()
            let reason = await callerCancellationReason(context, failure: failure)
            await finishRefreshWaiter(
                attempt: attempt,
                cancellationReason: reason)
            if reason != nil {
                throw .cancelled
            }
            throw failure
        case let .success(report):
            guard !Self.isExpired(report, at: currentDate()) else {
                _ = removeOwnedEntry(
                    attempt.generation,
                    connectionID: attempt.definition.id)
                await ready.disconnect()
                await finishRefreshWaiter(
                    attempt: attempt,
                    cancellationReason: nil)
                throw .contractViolation(.staleSession)
            }
            let refreshed = ready.replacingReport(report)
            let lease: DatabaseSessionLease
            switch entries[attempt.definition.id] {
            case let .refreshing(current, currentAttempt)
            where current.generation == attempt.generation
                && current.session.id == attempt.sessionID
                && currentAttempt.id == attempt.id:
                entries[attempt.definition.id] = .ready(refreshed)
                lease = refreshed.lease(source: .discovered)
            case let .ready(current)
            where current.generation == attempt.generation
                && current.session.id == attempt.sessionID:
                lease = current.lease(source: .discovered)
            case let .refreshing(current, _)
            where current.generation == attempt.generation
                && current.session.id == attempt.sessionID:
                lease = current.lease(source: .discovered)
            default:
                await ready.disconnect()
                await finishRefreshWaiter(
                    attempt: attempt,
                    cancellationReason: nil)
                throw .contractViolation(.staleSession)
            }
            do {
                let validated = try await validatedLease(
                    generation: lease.generation,
                    sessionID: lease.session.id,
                    connectionID: lease.definition.id,
                    source: lease.reportSource,
                    context: context)
                await finishRefreshWaiter(
                    attempt: attempt,
                    cancellationReason: nil)
                return validated
            } catch let failure {
                let reason = await callerCancellationReason(context, failure: failure)
                await finishRefreshWaiter(
                    attempt: attempt,
                    cancellationReason: reason)
                throw failure
            }
        }
    }

    private func validateCached(_ ready: DatabaseSessionReady) async -> Bool {
        guard ready.session.connection == ready.definition,
            ready.session.productIdentity.product == ready.definition.productHint
        else {
            return false
        }
        return await ready.session.lifecycleState() == .connected
    }

    private func owns(
        _ generation: DatabaseSessionGeneration,
        sessionID: DatabaseAdapterSessionID,
        connectionID: DatabaseConnectionID
    ) -> Bool {
        ownedReady(
            generation,
            sessionID: sessionID,
            connectionID: connectionID) != nil
    }

    private func ownedReady(
        _ generation: DatabaseSessionGeneration,
        sessionID: DatabaseAdapterSessionID,
        connectionID: DatabaseConnectionID
    ) -> DatabaseSessionReady? {
        guard let entry = entries[connectionID], entry.generation == generation else {
            return nil
        }
        let ready: DatabaseSessionReady
        switch entry {
        case .connecting:
            return nil
        case let .ready(current), let .refreshing(current, _):
            ready = current
        }
        guard ready.session.id == sessionID else { return nil }
        return ready
    }

    private func validatedLease(
        generation: DatabaseSessionGeneration,
        sessionID: DatabaseAdapterSessionID,
        connectionID: DatabaseConnectionID,
        source: DatabaseCapabilityReportSource,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseSessionLease {
        try await checkCallerContext(context)
        guard
            let ready = ownedReady(
                generation,
                sessionID: sessionID,
                connectionID: connectionID)
        else {
            throw .contractViolation(.staleSession)
        }
        let state = await ready.session.lifecycleState()
        let cancellationReason = await context.cancellation.reason()
        let deadlineExceeded = context.deadline.map { $0 <= currentDate() } ?? false
        guard !Task.isCancelled, cancellationReason == nil, !deadlineExceeded else {
            if deadlineExceeded {
                await context.cancellation.cancel(.deadlineExceeded)
            }
            throw .cancelled
        }
        guard
            let current = ownedReady(
                generation,
                sessionID: sessionID,
                connectionID: connectionID),
            state == .connected
        else {
            if let removed = removeOwnedEntry(
                generation,
                connectionID: connectionID)
            {
                await dispose(removed)
            }
            throw .contractViolation(.staleSession)
        }
        return current.lease(source: source)
    }

    private func callerCancellationReason(
        _ context: DatabaseAdapterOperationContext,
        failure: DatabaseAdapterFailure
    ) async -> DatabaseAdapterCancellationReason? {
        if let reason = await context.cancellation.reason() {
            return reason
        }
        if context.deadline.map({ $0 <= currentDate() }) ?? false {
            await context.cancellation.cancel(.deadlineExceeded)
            return .deadlineExceeded
        }
        if Task.isCancelled || failure == .cancelled {
            return .userRequested
        }
        return nil
    }

    private func checkCallerContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await context.checkCancellation()
        guard context.deadline.map({ $0 <= currentDate() }) != true else {
            await context.cancellation.cancel(.deadlineExceeded)
            throw .cancelled
        }
    }

    private func finishConnectWaiter(
        _ attempt: DatabaseSessionConnectAttempt,
        deliveredLease: Bool,
        cancellationReason: DatabaseAdapterCancellationReason?
    ) async {
        guard var waiters = connectWaiters[attempt.generation], waiters.count > 0 else {
            return
        }
        waiters.count -= 1
        waiters.deliveredLease = waiters.deliveredLease || deliveredLease
        guard waiters.count == 0 else {
            connectWaiters[attempt.generation] = waiters
            return
        }
        connectWaiters.removeValue(forKey: attempt.generation)
        let shouldDisconnect = cancellationReason != nil && !waiters.deliveredLease
        let removed: DatabaseSessionPoolEntry?
        if shouldDisconnect,
            entries[attempt.definition.id]?.generation == attempt.generation
        {
            removed = entries.removeValue(forKey: attempt.definition.id)
        } else {
            removed = nil
        }
        let completed = await attempt.completion.retire()
        guard let cancellationReason, shouldDisconnect else { return }
        attempt.task.cancel()
        markTaskRetired(attempt.generation.rawValue)
        await attempt.cancellation.cancel(cancellationReason)
        if let removed {
            await dispose(removed)
        }
        if let completed, case let .success(ready) = completed {
            await ready.disconnect()
        }
    }

    private func finishRefreshWaiter(
        attempt: DatabaseSessionRefreshAttempt,
        cancellationReason: DatabaseAdapterCancellationReason?
    ) async {
        guard var waiters = refreshWaiters[attempt.id], waiters.count > 0 else { return }
        waiters.count -= 1
        guard waiters.count == 0 else {
            refreshWaiters[attempt.id] = waiters
            return
        }
        refreshWaiters.removeValue(forKey: attempt.id)
        if let cancellationReason,
            case let .refreshing(ready, current)? = entries[attempt.definition.id],
            current.id == attempt.id
        {
            entries[attempt.definition.id] = .ready(ready)
            attempt.task.cancel()
            markTaskRetired(attempt.id)
            await attempt.cancellation.cancel(cancellationReason)
        }
        _ = await attempt.completion.retire()
    }

    private func waitShared<Value: Sendable>(
        completion: DatabaseSessionCompletionBroadcaster<Value>,
        context: DatabaseAdapterOperationContext,
        sharedCancellation: DatabaseAdapterCancellationSignal
    ) async -> DatabaseSessionWaitOutcome<Value> {
        let completionEvents = await completion.events()
        let callerEvents = await context.cancellation.events()
        let sharedEvents = await sharedCancellation.events()
        let deadline = context.deadline
        let outcome = await withTaskGroup(
            of: DatabaseSessionWaitOutcome<Value>?.self
        ) { group in
            group.addTask {
                var iterator = completionEvents.makeAsyncIterator()
                guard let result = await iterator.next() else { return nil }
                return .completed(result)
            }
            group.addTask {
                var iterator = callerEvents.makeAsyncIterator()
                guard let reason = await iterator.next() else { return nil }
                return .callerCancelled(reason)
            }
            group.addTask {
                var iterator = sharedEvents.makeAsyncIterator()
                guard let reason = await iterator.next() else { return nil }
                return .sharedCancelled(reason)
            }
            if let deadline {
                let delay = max(0, deadline.timeIntervalSince(currentDate()))
                let maximumDelay = Double(UInt64.max - 1_000_000) / 1_000_000_000
                let nanoseconds =
                    delay >= maximumDelay
                    ? UInt64.max - 1_000_000
                    : UInt64(delay * 1_000_000_000)
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return nil
                    }
                    guard !Task.isCancelled else { return nil }
                    return .callerCancelled(.deadlineExceeded)
                }
            }
            while let candidate = await group.next() {
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }
            return .callerCancelled(.userRequested)
        }
        switch outcome {
        case let .callerCancelled(reason), let .sharedCancelled(reason):
            await context.cancellation.cancel(reason)
        case .completed:
            break
        }
        return outcome
    }

    private func reserveTask(_ identifier: UUID) throws(DatabaseAdapterFailure) {
        guard trackedTasks[identifier] == nil else {
            throw .contractViolation(.staleSession)
        }
        guard trackedTasks.count < Self.maximumTrackedTasks else {
            throw .reported(
                DatabaseErrorEnvelope(
                    category: .resourceLimit,
                    message: "Too many database session tasks are still active."))
        }
        trackedTasks[identifier] = false
    }

    private func markTaskRetired(_ identifier: UUID) {
        guard trackedTasks[identifier] != nil else { return }
        trackedTasks[identifier] = true
    }

    private func finishTask(_ identifier: UUID) {
        trackedTasks.removeValue(forKey: identifier)
    }

    private func removeOwnedEntry(
        _ generation: DatabaseSessionGeneration,
        connectionID: DatabaseConnectionID
    ) -> DatabaseSessionPoolEntry? {
        guard entries[connectionID]?.generation == generation else { return nil }
        return entries.removeValue(forKey: connectionID)
    }

    private func isExpired(_ report: DatabaseCapabilityReport) -> Bool {
        Self.isExpired(report, at: currentDate())
    }

    private static func isExpired(
        _ report: DatabaseCapabilityReport,
        at date: Date
    ) -> Bool {
        report.expiresAt.map { $0 <= date } ?? false
    }

    private func dispose(_ entry: DatabaseSessionPoolEntry) async {
        switch entry {
        case let .connecting(attempt):
            connectWaiters.removeValue(forKey: attempt.generation)
            attempt.task.cancel()
            markTaskRetired(attempt.generation.rawValue)
            await attempt.cancellation.cancel(.sessionDisconnected)
            if let completed = await attempt.completion.retire(),
                case let .success(ready) = completed
            {
                await ready.disconnect()
            }
        case let .ready(ready):
            await ready.disconnect()
        case let .refreshing(ready, attempt):
            refreshWaiters.removeValue(forKey: attempt.id)
            attempt.task.cancel()
            markTaskRetired(attempt.id)
            await attempt.cancellation.cancel(.sessionDisconnected)
            _ = await attempt.completion.retire()
            await ready.disconnect()
        }
    }

    private static func establish(
        generation: DatabaseSessionGeneration,
        definition: DatabaseConnectionDefinition,
        registry: DatabaseAdapterRegistry,
        secretStore: any DatabaseSecretStore,
        currentDate: @escaping @Sendable () -> Date,
        context: DatabaseAdapterConnectionContext
    ) async -> Result<DatabaseSessionReady, DatabaseAdapterFailure> {
        var session: (any DatabaseAdapterSession)?
        do {
            try await context.checkCancellation()
            let secrets = try await resolveSecrets(
                definition: definition,
                secretStore: secretStore,
                context: context)
            let resolved = try DatabaseResolvedConnection(
                definition: definition,
                secrets: secrets)
            let redactor = try DatabaseSecretRedactor(secrets: Array(secrets.values))
            let adapter = try registry.adapter(for: definition.productHint)
            let connected = try await adapter.connect(resolved, context: context)
            session = connected
            try await context.checkCancellation()
            try await validate(
                session: connected,
                definition: definition)
            let report = try await connected.discoverCapabilities(context: context)
            try await context.checkCancellation()
            try await validate(
                session: connected,
                definition: definition,
                currentDate: currentDate,
                report: report)
            let sanitized = try DatabaseAdapterCapabilityReportSanitizer(
                redactor: redactor
            ).sanitize(
                report,
                identity: connected.productIdentity)
            return .success(
                DatabaseSessionReady(
                    generation: generation,
                    definition: definition,
                    session: connected,
                    report: sanitized,
                    redactor: redactor))
        } catch {
            if let session {
                await session.disconnect()
            }
            return .failure(normalize(error))
        }
    }

    private static func refresh(
        ready: DatabaseSessionReady,
        currentDate: @escaping @Sendable () -> Date,
        context: DatabaseAdapterOperationContext
    ) async -> Result<DatabaseCapabilityReport, DatabaseAdapterFailure> {
        do {
            try await context.checkCancellation()
            try await validate(
                session: ready.session,
                definition: ready.definition)
            let report = try await ready.session.discoverCapabilities(context: context)
            try await context.checkCancellation()
            try await validate(
                session: ready.session,
                definition: ready.definition,
                currentDate: currentDate,
                report: report)
            let sanitized = try DatabaseAdapterCapabilityReportSanitizer(
                redactor: ready.redactor
            ).sanitize(
                report,
                identity: ready.session.productIdentity)
            return .success(sanitized)
        } catch {
            return .failure(normalize(error))
        }
    }

    private static func validate(
        session: any DatabaseAdapterSession,
        definition: DatabaseConnectionDefinition,
        currentDate: (@Sendable () -> Date)? = nil,
        report: DatabaseCapabilityReport? = nil
    ) async throws(DatabaseAdapterFailure) {
        guard session.connection == definition,
            session.productIdentity.product == definition.productHint,
            await session.lifecycleState() == .connected
        else {
            throw .contractViolation(.staleSession)
        }
        guard let report else { return }
        try DatabaseAdapterBounds.validate(
            report: report,
            identity: session.productIdentity)
        guard report.discoveredAt <= (currentDate?() ?? Date()),
            report.expiresAt.map({ $0 > report.discoveredAt }) ?? true
        else {
            throw .contractViolation(.staleSession)
        }
    }

    private static func resolveSecrets(
        definition: DatabaseConnectionDefinition,
        secretStore: any DatabaseSecretStore,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> [DatabaseSecretReference: Data] {
        var references = definition.authentication.secretReferences
        if let privateKey = definition.tls.clientPrivateKey {
            guard privateKey.purpose == .clientPrivateKey else {
                throw invalidSecretReference()
            }
            references.append(privateKey)
        }
        var seen = Set<DatabaseSecretReference>()
        references = references.filter { seen.insert($0).inserted }
        guard
            references.allSatisfy({
                $0.purpose != .confirmationSigningKey
                    && $0.purpose != .continuationSigningKey
            })
        else {
            throw invalidSecretReference()
        }
        guard references.count <= DatabaseAdapterBounds.maximumResolvedSecrets else {
            throw .limitExceeded(
                limit: .resolvedSecrets,
                actual: references.count,
                maximum: DatabaseAdapterBounds.maximumResolvedSecrets)
        }
        var secrets: [DatabaseSecretReference: Data] = [:]
        secrets.reserveCapacity(references.count)
        for reference in references {
            try await context.checkCancellation()
            do {
                secrets[reference] = try await secretStore.read(reference)
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .reported(
                    DatabaseErrorEnvelope(
                        category: .authenticationFailed,
                        message: "A referenced connection secret could not be loaded.",
                        retry: DatabaseRetryGuidance(action: .reauthenticate)))
            }
        }
        try await context.checkCancellation()
        return secrets
    }

    private static func invalidSecretReference() -> DatabaseAdapterFailure {
        .reported(
            DatabaseErrorEnvelope(
                category: .invalidRequest,
                message: "The connection contains an invalid secret reference."))
    }

    private static func normalize(_ error: any Error) -> DatabaseAdapterFailure {
        if let failure = error as? DatabaseAdapterFailure {
            return failure
        }
        if error is CancellationError || Task.isCancelled {
            return .cancelled
        }
        return .reported(
            DatabaseErrorEnvelope(
                category: .internalFailure,
                message: "The database session could not be established."))
    }
}
