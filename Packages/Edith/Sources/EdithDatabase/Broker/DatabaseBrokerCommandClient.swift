import Dispatch
import Foundation

public protocol DatabaseBrokerCommandSending: Sendable {
    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse
}

public enum DatabaseBrokerCommandClientError: Error, Equatable, Sendable {
    case invalidRequest
    case timedOut
    case unavailable
    case unsafePeer
    case outcomeUnknown
}

public struct DatabaseBrokerCommandClient: DatabaseBrokerCommandSending, Sendable {
    static let defaultTransportBudgetNanoseconds: UInt64 = 30_000_000_000

    private let dependencies: DatabaseBrokerCommandClientDependencies

    public init(
        coordinator: DatabaseBrokerClientCoordinator = DatabaseBrokerClientCoordinator.shared
    ) {
        dependencies = .live(coordinator: coordinator)
    }

    init(dependencies: DatabaseBrokerCommandClientDependencies) {
        self.dependencies = dependencies
    }

    public func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        do {
            try await dependencies.ensureReady()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DatabaseBrokerAvailabilityError {
            throw DatabaseBrokerCommandClientError(error)
        } catch {
            throw DatabaseBrokerCommandClientError.unavailable
        }
        try Task.checkCancellation()

        let requestID = dependencies.makeRequestID()
        let deadlineNanoseconds = Self.deadline(
            startingAt: dependencies.monotonicNanoseconds(),
            budget: dependencies.transportBudgetNanoseconds)
        let work = DatabaseBrokerCommandClientWork()
        dependencies.queue.async {
            [dependencies, request, requestID, deadlineNanoseconds, work] in
            guard work.isPending else { return }
            guard dependencies.monotonicNanoseconds() < deadlineNanoseconds else {
                work.finishPreparation(.timedOut)
                return
            }
            let connection: DatabaseBrokerCommandClientConnection
            do {
                connection = try dependencies.makeConnection(deadlineNanoseconds)
            } catch {
                work.finishPreparation(
                    DatabaseBrokerCommandAttemptFailure(
                        preparationError: error))
                return
            }
            guard dependencies.monotonicNanoseconds() < deadlineNanoseconds else {
                connection.close()
                work.finishPreparation(.timedOut)
                return
            }
            guard work.install(connection) else { return }
            guard work.beginRequest() else {
                connection.close()
                return
            }
            let requestResult:
                Result<
                    DatabaseBrokerCommandResponse,
                    DatabaseBrokerCommandAttemptFailure
                >
            do {
                let response = try connection.request(
                    request,
                    requestID,
                    deadlineNanoseconds)
                requestResult = .success(response.payload)
            } catch {
                requestResult = .failure(
                    DatabaseBrokerCommandAttemptFailure(
                        requestError: error))
            }
            connection.close()
            work.finishRequest(requestResult)
        }
        return try await work.value()
    }

    static func deadline(
        startingAt start: UInt64,
        budget: UInt64
    ) -> UInt64 {
        let (deadline, overflow) = start.addingReportingOverflow(budget)
        return overflow ? UInt64.max : deadline
    }

    static func connectionTimeoutMilliseconds(
        deadlineNanoseconds: UInt64,
        nowNanoseconds: UInt64
    ) throws -> Int32 {
        guard nowNanoseconds < deadlineNanoseconds else {
            throw DatabaseBrokerSocketError.connectionTimedOut
        }
        let remainingNanoseconds = deadlineNanoseconds - nowNanoseconds
        let wholeMilliseconds = remainingNanoseconds / 1_000_000
        let roundedMilliseconds =
            wholeMilliseconds
            + (remainingNanoseconds.isMultiple(of: 1_000_000) ? 0 : 1)
        let cappedMilliseconds = min(
            max(roundedMilliseconds, 1),
            UInt64(DatabaseBrokerSocketConnection.maximumTimeoutMilliseconds))
        guard let timeout = Int32(exactly: cappedMilliseconds) else {
            throw DatabaseBrokerSocketError.invalidTimeout
        }
        return timeout
    }
}

struct DatabaseBrokerCommandClientDependencies: Sendable {
    let ensureReady: @Sendable () async throws -> Void
    let monotonicNanoseconds: @Sendable () -> UInt64
    let transportBudgetNanoseconds: UInt64
    let makeRequestID: @Sendable () -> UUID
    let makeConnection: @Sendable (UInt64) throws -> DatabaseBrokerCommandClientConnection
    let queue: DispatchQueue

    init(
        ensureReady: @escaping @Sendable () async throws -> Void,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        transportBudgetNanoseconds: UInt64 =
            DatabaseBrokerCommandClient.defaultTransportBudgetNanoseconds,
        makeRequestID: @escaping @Sendable () -> UUID = { UUID() },
        makeConnection:
            @escaping @Sendable (UInt64) throws -> DatabaseBrokerCommandClientConnection,
        queue: DispatchQueue = DispatchQueue(
            label: "com.edith.database.broker.command-client",
            qos: .userInitiated,
            attributes: .concurrent)
    ) {
        self.ensureReady = ensureReady
        self.monotonicNanoseconds = monotonicNanoseconds
        self.transportBudgetNanoseconds = transportBudgetNanoseconds
        self.makeRequestID = makeRequestID
        self.makeConnection = makeConnection
        self.queue = queue
    }
}

final class DatabaseBrokerCommandClientConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let requestImplementation:
        @Sendable (
            DatabaseBrokerCommandRequest,
            UUID,
            UInt64
        ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>
    private let closeImplementation: @Sendable () -> Void
    private var closed = false

    init(
        request:
            @escaping @Sendable (
                DatabaseBrokerCommandRequest,
                UUID,
                UInt64
            ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>,
        close: @escaping @Sendable () -> Void
    ) {
        requestImplementation = request
        closeImplementation = close
    }

    func request(
        _ request: DatabaseBrokerCommandRequest,
        _ requestID: UUID,
        _ deadlineNanoseconds: UInt64
    ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> {
        try requestImplementation(request, requestID, deadlineNanoseconds)
    }

    func close() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose {
            closeImplementation()
        }
    }
}

private enum DatabaseBrokerCommandClientWorkStage {
    case preparing
    case connected
    case requesting
}

private final class DatabaseBrokerCommandClientWork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var connection: DatabaseBrokerCommandClientConnection?
    private var continuation: CheckedContinuation<DatabaseBrokerCommandResponse, Error>?
    private var result: Result<DatabaseBrokerCommandResponse, Error>?
    private var stage = DatabaseBrokerCommandClientWorkStage.preparing

    var isPending: Bool {
        lock.withLock { result == nil }
    }

    func install(
        _ newConnection: DatabaseBrokerCommandClientConnection
    ) -> Bool {
        let installed = lock.withLock {
            guard result == nil, !cancellationRequested else { return false }
            connection = newConnection
            stage = .connected
            return true
        }
        if !installed {
            newConnection.close()
        }
        return installed
    }

    func beginRequest() -> Bool {
        lock.withLock {
            guard
                result == nil,
                !cancellationRequested,
                connection != nil
            else {
                return false
            }
            stage = .requesting
            return true
        }
    }

    func finishPreparation(_ failure: DatabaseBrokerCommandAttemptFailure) {
        resolve(.failure(failure.clientError))
    }

    func finishRequest(
        _ requestResult: Result<DatabaseBrokerCommandResponse, DatabaseBrokerCommandAttemptFailure>
    ) {
        resolve {
            switch requestResult {
            case .success(let response):
                return cancellationRequested
                    ? .failure(CancellationError())
                    : .success(response)
            case .failure(let failure):
                if cancellationRequested, failure.isReplaySafe {
                    return .failure(CancellationError())
                }
                return .failure(failure.clientError)
            }
        }
    }

    func value() async throws -> DatabaseBrokerCommandResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { newContinuation in
                let completedResult = lock.withLock {
                    guard result == nil else { return result }
                    continuation = newContinuation
                    return nil
                }
                if let completedResult {
                    newContinuation.resume(with: completedResult)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        let cancellation:
            (
                DatabaseBrokerCommandClientConnection?,
                CheckedContinuation<DatabaseBrokerCommandResponse, Error>?
            ) = lock.withLock {
                guard result == nil else { return (nil, nil) }
                cancellationRequested = true
                let activeConnection = connection
                guard stage != .requesting else {
                    return (activeConnection, nil)
                }
                let cancellationResult: Result<DatabaseBrokerCommandResponse, Error> =
                    .failure(CancellationError())
                result = cancellationResult
                let pendingContinuation = continuation
                continuation = nil
                connection = nil
                return (activeConnection, pendingContinuation)
            }
        cancellation.0?.close()
        cancellation.1?.resume(throwing: CancellationError())
    }

    private func resolve(
        _ makeResult: () -> Result<DatabaseBrokerCommandResponse, Error>
    ) {
        let resolution:
            (
                Result<DatabaseBrokerCommandResponse, Error>,
                CheckedContinuation<DatabaseBrokerCommandResponse, Error>?
            )? = lock.withLock {
                guard result == nil else { return nil }
                let completedResult = makeResult()
                result = completedResult
                let pendingContinuation = continuation
                continuation = nil
                connection = nil
                return (completedResult, pendingContinuation)
            }
        guard let resolution else { return }
        resolution.1?.resume(with: resolution.0)
    }

    private func resolve(
        _ result: Result<DatabaseBrokerCommandResponse, Error>
    ) {
        resolve { result }
    }
}

private enum DatabaseBrokerCommandAttemptFailure: Error, Equatable, Sendable {
    case invalidRequest
    case timedOut
    case unavailable
    case unsafePeer
    case outcomeUnknown

    init(preparationError error: Error) {
        if let error = error as? DatabaseBrokerSocketError {
            switch error {
            case .unsafeSocketEntry:
                self = .unsafePeer
            case .connectionTimedOut:
                self = .timedOut
            default:
                self = .unavailable
            }
            return
        }
        self = .unavailable
    }

    init(requestError error: Error) {
        if let error = error as? DatabaseBrokerCommandTransportError {
            if !error.isReplaySafe {
                self = .outcomeUnknown
            } else if error.failure == .invalidRequest {
                self = .invalidRequest
            } else {
                self = .unavailable
            }
            return
        }
        if let error = error as? DatabaseBrokerHealthTransportError {
            if !error.isReplaySafe {
                self = .outcomeUnknown
            } else if error.failure.isTimeout {
                self = .timedOut
            } else if case .authenticationFailed = error.failure {
                if error.failure == .authenticationFailed(.uniqueIdentifierMismatch) {
                    self = .unavailable
                } else {
                    self = .unsafePeer
                }
            } else {
                self = .unavailable
            }
            return
        }
        self = .outcomeUnknown
    }

    var isReplaySafe: Bool {
        self != .outcomeUnknown
    }

    var clientError: DatabaseBrokerCommandClientError {
        switch self {
        case .invalidRequest:
            .invalidRequest
        case .timedOut:
            .timedOut
        case .unavailable:
            .unavailable
        case .unsafePeer:
            .unsafePeer
        case .outcomeUnknown:
            .outcomeUnknown
        }
    }
}

private extension DatabaseBrokerHealthTransportFailure {
    var isTimeout: Bool {
        switch self {
        case .authenticationTimedOut, .readTimedOut, .writeProgressTimedOut:
            true
        case .authenticationFailed, .authenticationSystemFailure, .connectionClosed,
            .truncatedFrame, .multipleFrames, .readLimitExceeded, .invalidIOProgress,
            .ioFailure, .protocolFailure, .requestValidationFailure,
            .responseValidationFailure:
            false
        }
    }
}

extension DatabaseBrokerCommandClientDependencies {
    static func live(
        coordinator: DatabaseBrokerClientCoordinator
    ) -> DatabaseBrokerCommandClientDependencies {
        DatabaseBrokerCommandClientDependencies(
            ensureReady: {
                try await coordinator.ensureReady()
            },
            makeConnection: { deadlineNanoseconds in
                let transport = try DatabaseBrokerCommandTransport()
                let timeoutMilliseconds =
                    try DatabaseBrokerCommandClient
                    .connectionTimeoutMilliseconds(
                        deadlineNanoseconds: deadlineNanoseconds,
                        nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                let socket = try DatabaseBrokerSocketConnection.connect(
                    timeoutMilliseconds: timeoutMilliseconds)
                return DatabaseBrokerCommandClientConnection(
                    request: { request, requestID, requestDeadlineNanoseconds in
                        try socket.withSocketDescriptor { descriptor in
                            try transport.request(
                                request,
                                requestID: requestID,
                                socketDescriptor: descriptor,
                                deadlineNanoseconds: requestDeadlineNanoseconds)
                        }
                    },
                    close: {
                        socket.close()
                    })
            })
    }
}

extension DatabaseBrokerCommandClientError {
    init(_ error: DatabaseBrokerAvailabilityError) {
        switch error {
        case .unsafePeer:
            self = .unsafePeer
        case .outcomeUnknown:
            self = .outcomeUnknown
        case .readinessTimedOut, .versionTransitionTimedOut, .unavailable:
            self = .unavailable
        }
    }
}
