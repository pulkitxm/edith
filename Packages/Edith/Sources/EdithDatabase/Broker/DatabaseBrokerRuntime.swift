import Dispatch
import Foundation

enum DatabaseBrokerRuntimePhase: Equatable, Sendable {
    case starting
    case ready
    case draining
    case stopped
}

enum DatabaseBrokerRuntimeShutdownReason: Equatable, Sendable {
    case requested
    case startupFailure
    case acceptFailure
    case peerVersionMismatch
}

enum DatabaseBrokerRuntimeError: Error, Equatable, Sendable {
    case invalidPhase
}

struct DatabaseBrokerRuntimeSnapshot: Equatable, Sendable {
    let phase: DatabaseBrokerRuntimePhase
    let brokerInstanceID: UUID
    let isReady: Bool
    let activeClientCount: Int
    let shutdownReason: DatabaseBrokerRuntimeShutdownReason?
    let shutdownRequestCount: Int
}

enum DatabaseBrokerRuntimeClientResult: Equatable, Sendable {
    case completed(DatabaseBrokerHealthServerResult)
    case failed(DatabaseBrokerHealthTransportError)
    case unexpectedFailure

    var requestsPeerVersionShutdown: Bool {
        guard
            case .failed(let error) = self,
            case .authenticationFailed(.uniqueIdentifierMismatch) = error.failure
        else {
            return false
        }
        return true
    }
}

typealias DatabaseBrokerRuntimeHealthResponseProvider =
    @Sendable (DatabaseBrokerHealthRequest) -> DatabaseBrokerHealthResponse

struct DatabaseBrokerRuntimeConnection: @unchecked Sendable {
    let id: UUID
    private let serveHealthHandler:
        @Sendable (
            DatabaseBrokerHealthTransport,
            DatabaseBrokerRuntimeHealthResponseProvider
        ) throws -> DatabaseBrokerHealthServerResult
    private let closeHandler: @Sendable () -> Void

    init(
        id: UUID = UUID(),
        serveHealth:
            @escaping @Sendable (
                DatabaseBrokerHealthTransport,
                DatabaseBrokerRuntimeHealthResponseProvider
            ) throws -> DatabaseBrokerHealthServerResult,
        close: @escaping @Sendable () -> Void
    ) {
        self.id = id
        serveHealthHandler = serveHealth
        closeHandler = close
    }

    init(socketConnection: DatabaseBrokerSocketConnection) {
        id = UUID()
        serveHealthHandler = { transport, response in
            try socketConnection.withSocketDescriptor { socketDescriptor in
                try transport.serveHealth(
                    socketDescriptor: socketDescriptor,
                    response: response)
            }
        }
        closeHandler = {
            socketConnection.close()
        }
    }

    func serveHealth(
        using transport: DatabaseBrokerHealthTransport,
        response: DatabaseBrokerRuntimeHealthResponseProvider
    ) throws -> DatabaseBrokerHealthServerResult {
        try serveHealthHandler(transport, response)
    }

    func close() {
        closeHandler()
    }
}

struct DatabaseBrokerRuntimeListener: Sendable {
    private let socketDescriptorHandler: @Sendable () throws -> Int32
    private let acceptHandler: @Sendable () throws -> DatabaseBrokerRuntimeConnection?
    private let closeHandler: @Sendable () -> Void

    init(
        socketDescriptor: @escaping @Sendable () throws -> Int32,
        accept: @escaping @Sendable () throws -> DatabaseBrokerRuntimeConnection?,
        close: @escaping @Sendable () -> Void
    ) {
        socketDescriptorHandler = socketDescriptor
        acceptHandler = accept
        closeHandler = close
    }

    init(socketListener: DatabaseBrokerSocketListener) {
        socketDescriptorHandler = {
            try socketListener.withSocketDescriptor { $0 }
        }
        acceptHandler = {
            try socketListener.accept().map(DatabaseBrokerRuntimeConnection.init)
        }
        closeHandler = {
            socketListener.close()
        }
    }

    func socketDescriptor() throws -> Int32 {
        try socketDescriptorHandler()
    }

    func accept() throws -> DatabaseBrokerRuntimeConnection? {
        try acceptHandler()
    }

    func close() {
        closeHandler()
    }
}

struct DatabaseBrokerRuntimeTransport: Sendable {
    let serve:
        @Sendable (
            DatabaseBrokerRuntimeConnection,
            @escaping DatabaseBrokerRuntimeHealthResponseProvider
        ) async -> DatabaseBrokerRuntimeClientResult

    init(
        serve:
            @escaping @Sendable (
                DatabaseBrokerRuntimeConnection,
                @escaping DatabaseBrokerRuntimeHealthResponseProvider
            ) async -> DatabaseBrokerRuntimeClientResult
    ) {
        self.serve = serve
    }

    static func live() throws -> DatabaseBrokerRuntimeTransport {
        let transport = try DatabaseBrokerHealthTransport()
        let worker = DatabaseBrokerRuntimeHealthWorker(
            maximumConcurrentWorkItems: DatabaseBrokerRuntime.maximumActiveClients)
        return DatabaseBrokerRuntimeTransport { connection, response in
            await worker.perform {
                do {
                    return .completed(
                        try connection.serveHealth(
                            using: transport,
                            response: response))
                } catch let error as DatabaseBrokerHealthTransportError {
                    return .failed(error)
                } catch {
                    return .unexpectedFailure
                }
            }
        }
    }
}

struct DatabaseBrokerRuntimeAcceptSource: Sendable {
    private let activateHandler: @Sendable () -> Void
    private let cancelAndWaitHandler: @Sendable () async -> Void

    init(
        activate: @escaping @Sendable () -> Void,
        cancelAndWait: @escaping @Sendable () async -> Void
    ) {
        activateHandler = activate
        cancelAndWaitHandler = cancelAndWait
    }

    func activate() {
        activateHandler()
    }

    func cancelAndWait() async {
        await cancelAndWaitHandler()
    }

    static func live(
        socketDescriptor: Int32,
        onReadable: @escaping @Sendable () -> Void
    ) -> DatabaseBrokerRuntimeAcceptSource {
        let controller = DatabaseBrokerRuntimeReadSource(
            socketDescriptor: socketDescriptor,
            onReadable: onReadable)
        return DatabaseBrokerRuntimeAcceptSource(
            activate: {
                controller.activate()
            },
            cancelAndWait: {
                await controller.cancelAndWait()
            })
    }
}

protocol DatabaseBrokerRuntimeOwnership: Sendable {
    func release()
    func consumeIntoListener(
        paths: DatabaseBrokerPaths
    ) throws -> DatabaseBrokerRuntimeListener
}

private final class DatabaseBrokerLiveRuntimeOwnership:
    DatabaseBrokerRuntimeOwnership, @unchecked Sendable
{
    private enum State {
        case owned
        case consumed
        case released
    }

    private let stateLock = NSLock()
    private let runtimeLock: DatabaseRuntimeLock
    private var state = State.owned

    init(runtimeLock: DatabaseRuntimeLock) {
        self.runtimeLock = runtimeLock
    }

    func release() {
        stateLock.lock()
        guard case .owned = state else {
            stateLock.unlock()
            return
        }
        state = .released
        stateLock.unlock()
        runtimeLock.release()
    }

    func consumeIntoListener(
        paths: DatabaseBrokerPaths
    ) throws -> DatabaseBrokerRuntimeListener {
        stateLock.lock()
        guard case .owned = state else {
            stateLock.unlock()
            throw DatabaseRuntimeLockError.notHeld
        }
        state = .consumed
        stateLock.unlock()
        return DatabaseBrokerRuntimeListener(
            socketListener: try DatabaseBrokerSocketListener.listen(
                paths: paths,
                runtimeLock: runtimeLock))
    }

    deinit {
        release()
    }
}

struct DatabaseBrokerRuntimeDependencies: Sendable {
    let acquireOwnership:
        @Sendable (DatabaseBrokerPaths) throws -> any DatabaseBrokerRuntimeOwnership
    let makeTransport: @Sendable () throws -> DatabaseBrokerRuntimeTransport
    let makeAcceptSource:
        @Sendable (
            Int32,
            @escaping @Sendable () -> Void
        ) throws -> DatabaseBrokerRuntimeAcceptSource
    let observeShutdownRequest: @Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void

    static func live() -> DatabaseBrokerRuntimeDependencies {
        DatabaseBrokerRuntimeDependencies(
            acquireOwnership: { paths in
                DatabaseBrokerLiveRuntimeOwnership(
                    runtimeLock: try DatabaseBrokerSocketListener.acquireOwnership(
                        paths: paths))
            },
            makeTransport: {
                try DatabaseBrokerRuntimeTransport.live()
            },
            makeAcceptSource: { socketDescriptor, onReadable in
                DatabaseBrokerRuntimeAcceptSource.live(
                    socketDescriptor: socketDescriptor,
                    onReadable: onReadable)
            },
            observeShutdownRequest: { _ in })
    }
}

actor DatabaseBrokerRuntime {
    static let maximumActiveClients = 32
    static let maximumAcceptBatchSize = 8

    private struct StartupResources: Sendable {
        let transport: DatabaseBrokerRuntimeTransport
        let listener: DatabaseBrokerRuntimeListener
        let socketDescriptor: Int32
    }

    private struct ActiveClient {
        let connection: DatabaseBrokerRuntimeConnection
        let task: Task<Void, Never>
    }

    private let paths: DatabaseBrokerPaths
    private let dependencies: DatabaseBrokerRuntimeDependencies
    private let readiness: DatabaseBrokerRuntimeReadiness
    private var phase = DatabaseBrokerRuntimePhase.starting
    private var transport: DatabaseBrokerRuntimeTransport?
    private var listener: DatabaseBrokerRuntimeListener?
    private var acceptSource: DatabaseBrokerRuntimeAcceptSource?
    private var readableGate: DatabaseBrokerRuntimeReadableGate?
    private var activeClients: [UUID: ActiveClient] = [:]
    private var shutdownReason: DatabaseBrokerRuntimeShutdownReason?
    private var shutdownRequestCount = 0
    private var startupTask: Task<StartupResources, Error>?
    private var shutdownTask: Task<Void, Never>?
    private var stoppedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        paths: DatabaseBrokerPaths = DatabaseBrokerPaths(),
        brokerInstanceID: UUID = UUID(),
        dependencies: DatabaseBrokerRuntimeDependencies = .live()
    ) {
        self.paths = paths
        self.dependencies = dependencies
        readiness = DatabaseBrokerRuntimeReadiness(
            brokerInstanceID: brokerInstanceID)
    }

    func start() async throws {
        guard
            phase == .starting,
            listener == nil,
            acceptSource == nil,
            startupTask == nil
        else {
            throw DatabaseBrokerRuntimeError.invalidPhase
        }

        let paths = paths
        let dependencies = dependencies
        let startupTask = Task.detached(priority: .userInitiated) {
            let ownership = try dependencies.acquireOwnership(paths)
            let transport: DatabaseBrokerRuntimeTransport
            do {
                try Task.checkCancellation()
                transport = try dependencies.makeTransport()
                try Task.checkCancellation()
            } catch {
                ownership.release()
                throw error
            }
            let listener: DatabaseBrokerRuntimeListener
            do {
                listener = try ownership.consumeIntoListener(paths: paths)
            } catch {
                ownership.release()
                throw error
            }
            do {
                try Task.checkCancellation()
                return StartupResources(
                    transport: transport,
                    listener: listener,
                    socketDescriptor: try listener.socketDescriptor())
            } catch {
                listener.close()
                throw error
            }
        }
        self.startupTask = startupTask

        let startup: StartupResources
        do {
            startup = try await startupTask.value
        } catch {
            self.startupTask = nil
            if phase == .starting {
                recordStartupFailure()
            }
            throw error
        }
        self.startupTask = nil

        guard phase == .starting else {
            startup.listener.close()
            throw DatabaseBrokerRuntimeError.invalidPhase
        }

        let gate = DatabaseBrokerRuntimeReadableGate { [weak self] in
            guard let self else { return }
            Task {
                await self.acceptReadableConnections()
            }
        }
        do {
            let createdAcceptSource = try dependencies.makeAcceptSource(
                startup.socketDescriptor
            ) {
                gate.readable()
            }
            transport = startup.transport
            listener = startup.listener
            acceptSource = createdAcceptSource
            readableGate = gate
            createdAcceptSource.activate()
            phase = .ready
            readiness.setReady(true)
        } catch {
            gate.close()
            startup.listener.close()
            recordStartupFailure()
            throw error
        }
    }

    func shutdown() async {
        beginShutdown(reason: .requested)
        await waitUntilStopped()
    }

    func waitUntilStopped() async {
        guard phase != .stopped else { return }
        await withCheckedContinuation { continuation in
            stoppedWaiters.append(continuation)
        }
    }

    func snapshot() -> DatabaseBrokerRuntimeSnapshot {
        let readinessSnapshot = readiness.snapshot()
        return DatabaseBrokerRuntimeSnapshot(
            phase: phase,
            brokerInstanceID: readinessSnapshot.brokerInstanceID,
            isReady: readinessSnapshot.isReady,
            activeClientCount: activeClients.count,
            shutdownReason: shutdownReason,
            shutdownRequestCount: shutdownRequestCount)
    }

    private func acceptReadableConnections() {
        guard let readableGate else { return }
        var shouldReschedule = false
        defer {
            readableGate.drainCompleted(
                shouldReschedule: shouldReschedule)
        }
        guard
            phase == .ready,
            let listener,
            let transport
        else {
            return
        }

        for _ in 0..<Self.maximumAcceptBatchSize {
            guard phase == .ready else { return }
            let connection: DatabaseBrokerRuntimeConnection
            do {
                guard let acceptedConnection = try listener.accept() else {
                    return
                }
                connection = acceptedConnection
            } catch {
                beginShutdown(reason: .acceptFailure)
                return
            }

            guard
                activeClients.count < Self.maximumActiveClients,
                activeClients[connection.id] == nil
            else {
                connection.close()
                continue
            }

            let readiness = readiness
            let runtime = self
            let task = Task.detached(priority: .userInitiated) {
                let result = await transport.serve(connection) { _ in
                    readiness.response()
                }
                await runtime.clientFinished(
                    connectionID: connection.id,
                    result: result)
            }
            activeClients[connection.id] = ActiveClient(
                connection: connection,
                task: task)
        }
        shouldReschedule = phase == .ready
    }

    private func clientFinished(
        connectionID: UUID,
        result: DatabaseBrokerRuntimeClientResult
    ) {
        guard let client = activeClients.removeValue(forKey: connectionID) else {
            return
        }
        if result.requestsPeerVersionShutdown {
            beginShutdown(
                reason: .peerVersionMismatch,
                additionalConnections: [client.connection])
            return
        }
        if phase == .ready {
            client.connection.close()
        }
    }

    private func beginShutdown(
        reason: DatabaseBrokerRuntimeShutdownReason,
        additionalConnections: [DatabaseBrokerRuntimeConnection] = []
    ) {
        guard phase == .starting || phase == .ready else { return }
        phase = .draining
        readiness.setReady(false)
        readableGate?.close()
        shutdownReason = reason
        shutdownRequestCount = 1
        dependencies.observeShutdownRequest(reason)

        let source = acceptSource
        let clients = Array(activeClients.values)
        let listener = listener
        let startupTask = startupTask
        startupTask?.cancel()
        let runtime = self
        let task = Task.detached(priority: .userInitiated) {
            await source?.cancelAndWait()
            var closedConnectionIDs = Set<UUID>()
            for connection in additionalConnections + clients.map(\.connection) {
                guard closedConnectionIDs.insert(connection.id).inserted else {
                    continue
                }
                connection.close()
            }
            for client in clients {
                client.task.cancel()
            }
            for client in clients {
                await client.task.value
            }
            if let startupTask,
                let startup = try? await startupTask.value
            {
                startup.listener.close()
            }
            listener?.close()
            await runtime.finishShutdown()
        }
        shutdownTask = task
    }

    private func finishShutdown() {
        activeClients.removeAll(keepingCapacity: false)
        acceptSource = nil
        readableGate = nil
        listener = nil
        transport = nil
        startupTask = nil
        shutdownTask = nil
        phase = .stopped
        let waiters = stoppedWaiters
        stoppedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recordStartupFailure() {
        readiness.setReady(false)
        phase = .stopped
        shutdownReason = .startupFailure
        shutdownRequestCount = 1
        dependencies.observeShutdownRequest(.startupFailure)
        let waiters = stoppedWaiters
        stoppedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

final class DatabaseBrokerRuntimeReadableGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private let scheduleHandler: @Sendable () -> Void
    private var isScheduled = false
    private var hasPendingReadableEvent = false
    private var isClosed = false

    init(schedule: @escaping @Sendable () -> Void) {
        scheduleHandler = schedule
    }

    func readable() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        if isScheduled {
            hasPendingReadableEvent = true
            stateLock.unlock()
            return
        }
        isScheduled = true
        stateLock.unlock()
        scheduleHandler()
    }

    func drainCompleted(shouldReschedule: Bool) {
        stateLock.lock()
        guard !isClosed else {
            isScheduled = false
            hasPendingReadableEvent = false
            stateLock.unlock()
            return
        }
        let scheduleAgain = shouldReschedule || hasPendingReadableEvent
        hasPendingReadableEvent = false
        isScheduled = scheduleAgain
        stateLock.unlock()
        if scheduleAgain {
            scheduleHandler()
        }
    }

    func close() {
        stateLock.withLock {
            isClosed = true
            hasPendingReadableEvent = false
        }
    }
}

private final class DatabaseBrokerRuntimeReadiness: @unchecked Sendable {
    struct Snapshot: Sendable {
        let brokerInstanceID: UUID
        let isReady: Bool
    }

    private let stateLock = NSLock()
    private let brokerInstanceID: UUID
    private var isReady = false

    init(brokerInstanceID: UUID) {
        self.brokerInstanceID = brokerInstanceID
    }

    func setReady(_ isReady: Bool) {
        stateLock.withLock {
            self.isReady = isReady
        }
    }

    func snapshot() -> Snapshot {
        stateLock.withLock {
            Snapshot(
                brokerInstanceID: brokerInstanceID,
                isReady: isReady)
        }
    }

    func response() -> DatabaseBrokerHealthResponse {
        let snapshot = snapshot()
        return DatabaseBrokerHealthResponse(
            brokerInstanceID: snapshot.brokerInstanceID,
            isReady: snapshot.isReady)
    }
}

private final class DatabaseBrokerRuntimeHealthWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.pulkitxm.edith.database-broker.health-workers",
        qos: .userInitiated,
        attributes: .concurrent)
    private let permits: DispatchSemaphore

    init(maximumConcurrentWorkItems: Int) {
        permits = DispatchSemaphore(value: maximumConcurrentWorkItems)
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                self.permits.wait()
                let result = operation()
                self.permits.signal()
                continuation.resume(returning: result)
            }
        }
    }
}

private final class DatabaseBrokerRuntimeReadSource: @unchecked Sendable {
    private enum State {
        case inactive
        case active
        case cancelling
        case cancelled
    }

    private let stateLock = NSLock()
    private let source: DispatchSourceRead
    private var state = State.inactive
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        socketDescriptor: Int32,
        onReadable: @escaping @Sendable () -> Void
    ) {
        let queue = DispatchQueue(
            label: "com.pulkitxm.edith.database-broker.accept")
        source = DispatchSource.makeReadSource(
            fileDescriptor: socketDescriptor,
            queue: queue)
        source.setEventHandler(handler: onReadable)
        source.setCancelHandler { [weak self] in
            self?.completeCancellation()
        }
    }

    func activate() {
        stateLock.lock()
        guard case .inactive = state else {
            stateLock.unlock()
            return
        }
        state = .active
        stateLock.unlock()
        source.activate()
    }

    func cancelAndWait() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            let shouldCancel: Bool
            let shouldActivate: Bool
            switch state {
            case .inactive:
                state = .cancelling
                cancellationWaiters.append(continuation)
                shouldCancel = true
                shouldActivate = true
            case .active:
                state = .cancelling
                cancellationWaiters.append(continuation)
                shouldCancel = true
                shouldActivate = false
            case .cancelling:
                cancellationWaiters.append(continuation)
                shouldCancel = false
                shouldActivate = false
            case .cancelled:
                shouldCancel = false
                shouldActivate = false
            }
            let isAlreadyCancelled = state == .cancelled
            stateLock.unlock()

            if isAlreadyCancelled {
                continuation.resume()
                return
            }
            if shouldCancel {
                source.cancel()
            }
            if shouldActivate {
                source.activate()
            }
        }
    }

    private func completeCancellation() {
        stateLock.lock()
        state = .cancelled
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll(keepingCapacity: false)
        stateLock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
