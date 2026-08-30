import Dispatch
import Foundation

public protocol DatabaseBrokerCommandSending: Sendable {
    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse
}

public enum DatabaseBrokerCommandClientError: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case unsafePeer
    case outcomeUnknown
}

public struct DatabaseBrokerCommandClient: DatabaseBrokerCommandSending, Sendable {
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
        let work = DatabaseBrokerCommandClientWork()
        dependencies.queue.async { [dependencies, request, requestID, work] in
            guard work.isPending else { return }
            let connection: DatabaseBrokerCommandClientConnection
            do {
                connection = try dependencies.makeConnection()
            } catch {
                work.finishPreparation(
                    DatabaseBrokerCommandAttemptFailure(
                        preparationError: error))
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
                let response = try connection.request(request, requestID)
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
}

struct DatabaseBrokerCommandClientDependencies: Sendable {
    let ensureReady: @Sendable () async throws -> Void
    let makeRequestID: @Sendable () -> UUID
    let makeConnection: @Sendable () throws -> DatabaseBrokerCommandClientConnection
    let queue: DispatchQueue

    init(
        ensureReady: @escaping @Sendable () async throws -> Void,
        makeRequestID: @escaping @Sendable () -> UUID = { UUID() },
        makeConnection:
            @escaping @Sendable () throws -> DatabaseBrokerCommandClientConnection,
        queue: DispatchQueue = DispatchQueue(
            label: "com.edith.database.broker.command-client",
            qos: .userInitiated,
            attributes: .concurrent)
    ) {
        self.ensureReady = ensureReady
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
            UUID
        ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>
    private let closeImplementation: @Sendable () -> Void
    private var closed = false

    init(
        request:
            @escaping @Sendable (
                DatabaseBrokerCommandRequest,
                UUID
            ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>,
        close: @escaping @Sendable () -> Void
    ) {
        requestImplementation = request
        closeImplementation = close
    }

    func request(
        _ request: DatabaseBrokerCommandRequest,
        _ requestID: UUID
    ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> {
        try requestImplementation(request, requestID)
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
    case unavailable
    case unsafePeer
    case outcomeUnknown

    init(preparationError error: Error) {
        if let error = error as? DatabaseBrokerSocketError,
            error == .unsafeSocketEntry
        {
            self = .unsafePeer
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
        case .unavailable:
            .unavailable
        case .unsafePeer:
            .unsafePeer
        case .outcomeUnknown:
            .outcomeUnknown
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
            makeConnection: {
                let transport = try DatabaseBrokerCommandTransport()
                let socket = try DatabaseBrokerSocketConnection.connect()
                return DatabaseBrokerCommandClientConnection(
                    request: { request, requestID in
                        try socket.withSocketDescriptor { descriptor in
                            try transport.request(
                                request,
                                requestID: requestID,
                                socketDescriptor: descriptor)
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
