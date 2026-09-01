import Darwin
import Dispatch
import Foundation

enum DatabaseBrokerHealthTransportFailure: Equatable, Sendable {
    case authenticationFailed(DatabaseBrokerPeerAuthenticationError)
    case authenticationSystemFailure
    case authenticationTimedOut
    case readTimedOut
    case writeProgressTimedOut
    case connectionClosed
    case truncatedFrame
    case multipleFrames
    case readLimitExceeded
    case invalidIOProgress
    case ioFailure
    case protocolFailure(DatabaseBrokerProtocolError)
    case requestValidationFailure(DatabaseBrokerHealthValidationError)
    case responseValidationFailure(DatabaseBrokerHealthValidationError)
}

struct DatabaseBrokerHealthTransportError: Error, Equatable, Sendable {
    let failure: DatabaseBrokerHealthTransportFailure
    let bytesWritten: Int

    var isReplaySafe: Bool {
        bytesWritten == 0
    }
}

enum DatabaseBrokerHealthServerResponseDisposition: Equatable, Sendable {
    case sent
    case responseSinkDropped
}

struct DatabaseBrokerHealthServerResult: Equatable, Sendable {
    let requestID: UUID
    let disposition: DatabaseBrokerHealthServerResponseDisposition
    let responseBytesWritten: Int
}

enum DatabaseBrokerHealthTransportWaitInterest: Equatable, Sendable {
    case readable
    case writable
}

enum DatabaseBrokerHealthTransportWaitResult: Equatable, Sendable {
    case ready
    case timedOut
    case interrupted
    case disconnected
}

enum DatabaseBrokerHealthTransportReadResult: Equatable, Sendable {
    case bytes(Data)
    case wouldBlock
    case endOfFile
    case timedOut
}

enum DatabaseBrokerHealthTransportWriteResult: Equatable, Sendable {
    case bytes(Int)
    case wouldBlock
    case sinkClosed
    case timedOut
}

enum DatabaseBrokerHealthTransportAuthenticationResult: Equatable, Sendable {
    case authenticated
    case failed(DatabaseBrokerPeerAuthenticationError)
    case systemFailure
    case timedOut
}

struct DatabaseBrokerHealthTransportDependencies: Sendable {
    let monotonicNanoseconds: @Sendable () -> UInt64
    let authenticatePeer:
        @Sendable (
            Int32,
            UInt64,
            UInt64?
        ) -> DatabaseBrokerHealthTransportAuthenticationResult
    let wait:
        @Sendable (
            Int32,
            DatabaseBrokerHealthTransportWaitInterest,
            UInt64
        ) throws -> DatabaseBrokerHealthTransportWaitResult
    let read:
        @Sendable (
            Int32,
            Int,
            UInt64?
        ) throws -> DatabaseBrokerHealthTransportReadResult
    let write:
        @Sendable (
            Int32,
            Data,
            Int,
            UInt64?
        ) throws -> DatabaseBrokerHealthTransportWriteResult

    init(
        monotonicNanoseconds: @escaping @Sendable () -> UInt64,
        authenticatePeer:
            @escaping @Sendable (
                Int32,
                UInt64,
                UInt64?
            ) -> DatabaseBrokerHealthTransportAuthenticationResult,
        wait:
            @escaping @Sendable (
                Int32,
                DatabaseBrokerHealthTransportWaitInterest,
                UInt64
            ) throws -> DatabaseBrokerHealthTransportWaitResult,
        read:
            @escaping @Sendable (
                Int32,
                Int,
                UInt64?
            ) throws -> DatabaseBrokerHealthTransportReadResult,
        write:
            @escaping @Sendable (
                Int32,
                Data,
                Int,
                UInt64?
            ) throws -> DatabaseBrokerHealthTransportWriteResult
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.authenticatePeer = authenticatePeer
        self.wait = wait
        self.read = read
        self.write = write
    }
}

struct DatabaseBrokerHealthTransport: Sendable {
    static let maximumReadBytes = 64 * 1_024
    static let authenticationBudgetNanoseconds: UInt64 = 2_000_000_000
    static let firstByteBudgetNanoseconds: UInt64 = 5_000_000_000
    static let frameBudgetNanoseconds: UInt64 = 5_000_000_000
    static let writeProgressBudgetNanoseconds: UInt64 = 5_000_000_000

    let dependencies: DatabaseBrokerHealthTransportDependencies

    init() throws {
        try self.init(authenticator: DatabaseBrokerPeerAuthenticator())
    }

    init(authenticator: DatabaseBrokerPeerAuthenticator) {
        dependencies = DatabaseBrokerHealthTransportDependencies.live(
            authenticator: authenticator)
    }

    init(dependencies: DatabaseBrokerHealthTransportDependencies) {
        self.dependencies = dependencies
    }

    func requestHealth(
        socketDescriptor: Int32,
        requestID: UUID = UUID(),
        deadlineNanoseconds: UInt64? = nil
    ) throws -> DatabaseBrokerHealthResponse {
        try authenticatePeer(
            socketDescriptor: socketDescriptor,
            absoluteDeadline: deadlineNanoseconds)
        let request = DatabaseBrokerEnvelope(
            requestID: requestID,
            sequence: 0,
            kind: DatabaseBrokerEnvelopeKind.request,
            payload: DatabaseBrokerHealthRequest())
        let responseValidator: DatabaseBrokerHealthResponseValidator
        do {
            responseValidator = try DatabaseBrokerHealthResponseValidator(request: request)
        } catch {
            throw transportError(
                .requestValidationFailure(error),
                bytesWritten: 0)
        }
        let requestFrame = try encode(
            request,
            stream: .requests,
            bytesWritten: 0)
        let writeOutcome = try writeFrame(
            requestFrame,
            socketDescriptor: socketDescriptor,
            sinkClosureIsResult: false,
            absoluteDeadline: deadlineNanoseconds)
        let response: DatabaseBrokerEnvelope<DatabaseBrokerHealthResponse> = try readFrame(
            socketDescriptor: socketDescriptor,
            stream: .responses,
            bytesWritten: writeOutcome.bytesWritten,
            absoluteDeadline: deadlineNanoseconds)
        var validator = responseValidator
        do {
            try validator.validate(response)
            try validator.finish()
        } catch {
            throw transportError(
                .responseValidationFailure(error),
                bytesWritten: writeOutcome.bytesWritten)
        }
        return response.payload
    }

    func serveHealth(
        socketDescriptor: Int32,
        response: @Sendable (DatabaseBrokerHealthRequest) -> DatabaseBrokerHealthResponse
    ) throws -> DatabaseBrokerHealthServerResult {
        try authenticatePeer(
            socketDescriptor: socketDescriptor,
            absoluteDeadline: nil)
        let request: DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest> = try readFrame(
            socketDescriptor: socketDescriptor,
            stream: .requests,
            bytesWritten: 0,
            absoluteDeadline: nil)
        do {
            try DatabaseBrokerHealthRequestValidator.validate(request)
        } catch {
            throw transportError(
                .requestValidationFailure(error),
                bytesWritten: 0)
        }
        let responsePayload = response(request.payload)
        let responseEnvelope = DatabaseBrokerEnvelope(
            requestID: request.requestID,
            sequence: 0,
            kind: DatabaseBrokerEnvelopeKind.response,
            payload: responsePayload)
        let responseFrame = try encode(
            responseEnvelope,
            stream: .responses,
            bytesWritten: 0)
        let writeOutcome = try writeFrame(
            responseFrame,
            socketDescriptor: socketDescriptor,
            sinkClosureIsResult: true,
            absoluteDeadline: nil)
        return DatabaseBrokerHealthServerResult(
            requestID: request.requestID,
            disposition: writeOutcome.sinkClosed ? .responseSinkDropped : .sent,
            responseBytesWritten: writeOutcome.bytesWritten)
    }

    func authenticatePeer(
        socketDescriptor: Int32,
        absoluteDeadline: UInt64?
    ) throws {
        let startedAt = dependencies.monotonicNanoseconds()
        let authenticationDeadline = cappedDeadline(
            budget: Self.authenticationBudgetNanoseconds,
            startingAt: startedAt,
            absoluteDeadline: absoluteDeadline)
        guard startedAt < authenticationDeadline else {
            throw transportError(.authenticationTimedOut, bytesWritten: 0)
        }
        let result = dependencies.authenticatePeer(
            socketDescriptor,
            authenticationDeadline - startedAt,
            authenticationDeadline)
        if dependencies.monotonicNanoseconds() >= authenticationDeadline {
            throw transportError(.authenticationTimedOut, bytesWritten: 0)
        }
        switch result {
        case .authenticated:
            return
        case .failed(let error):
            throw transportError(.authenticationFailed(error), bytesWritten: 0)
        case .systemFailure:
            throw transportError(.authenticationSystemFailure, bytesWritten: 0)
        case .timedOut:
            throw transportError(.authenticationTimedOut, bytesWritten: 0)
        }
    }

    private func encode<Payload: Codable & Sendable>(
        _ envelope: DatabaseBrokerEnvelope<Payload>,
        stream: DatabaseBrokerFrameStream,
        bytesWritten: Int
    ) throws -> Data {
        do {
            return try DatabaseBrokerFrameCodec.encode(envelope, stream: stream)
        } catch {
            throw transportError(
                .protocolFailure(error),
                bytesWritten: bytesWritten)
        }
    }

    func readFrame<Payload: Codable & Sendable>(
        socketDescriptor: Int32,
        stream: DatabaseBrokerFrameStream,
        bytesWritten: Int,
        absoluteDeadline: UInt64?
    ) throws -> DatabaseBrokerEnvelope<Payload> {
        var decoder = DatabaseBrokerIncrementalDecoder<Payload>(stream: stream)
        var frameDeadline: UInt64?
        let firstByteDeadline = cappedDeadline(
            budget: Self.firstByteBudgetNanoseconds,
            startingAt: dependencies.monotonicNanoseconds(),
            absoluteDeadline: absoluteDeadline)

        while true {
            let deadline = frameDeadline ?? firstByteDeadline
            guard dependencies.monotonicNanoseconds() < deadline else {
                throw transportError(.readTimedOut, bytesWritten: bytesWritten)
            }

            let readResult: DatabaseBrokerHealthTransportReadResult
            do {
                readResult = try dependencies.read(
                    socketDescriptor,
                    Self.maximumReadBytes,
                    deadline)
            } catch {
                throw transportError(.ioFailure, bytesWritten: bytesWritten)
            }
            if dependencies.monotonicNanoseconds() >= deadline {
                throw transportError(.readTimedOut, bytesWritten: bytesWritten)
            }

            switch readResult {
            case .bytes(let chunk):
                guard !chunk.isEmpty else {
                    throw transportError(.invalidIOProgress, bytesWritten: bytesWritten)
                }
                guard chunk.count <= Self.maximumReadBytes else {
                    throw transportError(.readLimitExceeded, bytesWritten: bytesWritten)
                }
                let observedAt = dependencies.monotonicNanoseconds()
                if frameDeadline == nil {
                    guard observedAt < firstByteDeadline else {
                        throw transportError(.readTimedOut, bytesWritten: bytesWritten)
                    }
                    frameDeadline = cappedDeadline(
                        budget: Self.frameBudgetNanoseconds,
                        startingAt: observedAt,
                        absoluteDeadline: absoluteDeadline)
                } else {
                    guard let frameDeadline, observedAt < frameDeadline else {
                        throw transportError(.readTimedOut, bytesWritten: bytesWritten)
                    }
                }
                let envelopes: [DatabaseBrokerEnvelope<Payload>]
                do {
                    envelopes = try decoder.append(chunk)
                } catch {
                    throw transportError(
                        .protocolFailure(error),
                        bytesWritten: bytesWritten)
                }
                guard envelopes.count <= 1 else {
                    throw transportError(.multipleFrames, bytesWritten: bytesWritten)
                }
                if let envelope = envelopes.first {
                    guard decoder.bufferedByteCount == 0 else {
                        throw transportError(.multipleFrames, bytesWritten: bytesWritten)
                    }
                    do {
                        try decoder.finish()
                    } catch {
                        throw transportError(
                            .protocolFailure(error),
                            bytesWritten: bytesWritten)
                    }
                    let trailingRead: DatabaseBrokerHealthTransportReadResult
                    let trailingReadDeadline = frameDeadline ?? deadline
                    do {
                        trailingRead = try dependencies.read(
                            socketDescriptor,
                            Self.maximumReadBytes,
                            trailingReadDeadline)
                    } catch {
                        throw transportError(.ioFailure, bytesWritten: bytesWritten)
                    }
                    if dependencies.monotonicNanoseconds() >= trailingReadDeadline {
                        throw transportError(.readTimedOut, bytesWritten: bytesWritten)
                    }
                    switch trailingRead {
                    case .bytes(let trailingBytes):
                        guard !trailingBytes.isEmpty else {
                            throw transportError(
                                .invalidIOProgress,
                                bytesWritten: bytesWritten)
                        }
                        guard trailingBytes.count <= Self.maximumReadBytes else {
                            throw transportError(
                                .readLimitExceeded,
                                bytesWritten: bytesWritten)
                        }
                        throw transportError(.multipleFrames, bytesWritten: bytesWritten)
                    case .timedOut:
                        throw transportError(.readTimedOut, bytesWritten: bytesWritten)
                    case .wouldBlock, .endOfFile:
                        return envelope
                    }
                }
            case .wouldBlock:
                let waitResult = try waitForReadiness(
                    socketDescriptor: socketDescriptor,
                    interest: .readable,
                    deadline: deadline,
                    timeoutFailure: .readTimedOut,
                    bytesWritten: bytesWritten)
                if dependencies.monotonicNanoseconds() >= deadline {
                    throw transportError(.readTimedOut, bytesWritten: bytesWritten)
                }
                if waitResult == .disconnected {
                    continue
                }
            case .endOfFile:
                do {
                    try decoder.finish()
                } catch DatabaseBrokerProtocolError.truncatedFrame {
                    throw transportError(.truncatedFrame, bytesWritten: bytesWritten)
                } catch {
                    throw transportError(
                        .protocolFailure(error),
                        bytesWritten: bytesWritten)
                }
                throw transportError(.connectionClosed, bytesWritten: bytesWritten)
            case .timedOut:
                throw transportError(.readTimedOut, bytesWritten: bytesWritten)
            }
        }
    }

    func writeFrame(
        _ frame: Data,
        socketDescriptor: Int32,
        sinkClosureIsResult: Bool,
        absoluteDeadline: UInt64?
    ) throws -> DatabaseBrokerHealthWriteOutcome {
        var offset = 0
        var progressDeadline = cappedDeadline(
            budget: Self.writeProgressBudgetNanoseconds,
            startingAt: dependencies.monotonicNanoseconds(),
            absoluteDeadline: absoluteDeadline)

        while offset < frame.count {
            guard dependencies.monotonicNanoseconds() < progressDeadline else {
                throw transportError(.writeProgressTimedOut, bytesWritten: offset)
            }
            let writeResult: DatabaseBrokerHealthTransportWriteResult
            do {
                writeResult = try dependencies.write(
                    socketDescriptor,
                    frame,
                    offset,
                    progressDeadline)
            } catch {
                throw transportError(.ioFailure, bytesWritten: offset)
            }
            switch writeResult {
            case .bytes(let count):
                guard count > 0, count <= frame.count - offset else {
                    throw transportError(.invalidIOProgress, bytesWritten: offset)
                }
                offset += count
                guard dependencies.monotonicNanoseconds() < progressDeadline else {
                    throw transportError(.writeProgressTimedOut, bytesWritten: offset)
                }
                progressDeadline = cappedDeadline(
                    budget: Self.writeProgressBudgetNanoseconds,
                    startingAt: dependencies.monotonicNanoseconds(),
                    absoluteDeadline: absoluteDeadline)
            case .wouldBlock:
                let waitResult = try waitForReadiness(
                    socketDescriptor: socketDescriptor,
                    interest: .writable,
                    deadline: progressDeadline,
                    timeoutFailure: .writeProgressTimedOut,
                    bytesWritten: offset)
                if dependencies.monotonicNanoseconds() >= progressDeadline {
                    throw transportError(.writeProgressTimedOut, bytesWritten: offset)
                }
                if waitResult == .disconnected {
                    if sinkClosureIsResult {
                        return DatabaseBrokerHealthWriteOutcome(
                            bytesWritten: offset,
                            sinkClosed: true)
                    }
                    throw transportError(.connectionClosed, bytesWritten: offset)
                }
            case .sinkClosed:
                if dependencies.monotonicNanoseconds() >= progressDeadline {
                    throw transportError(.writeProgressTimedOut, bytesWritten: offset)
                }
                if sinkClosureIsResult {
                    return DatabaseBrokerHealthWriteOutcome(
                        bytesWritten: offset,
                        sinkClosed: true)
                }
                throw transportError(.connectionClosed, bytesWritten: offset)
            case .timedOut:
                throw transportError(.writeProgressTimedOut, bytesWritten: offset)
            }
        }

        return DatabaseBrokerHealthWriteOutcome(
            bytesWritten: offset,
            sinkClosed: false)
    }

    private func waitForReadiness(
        socketDescriptor: Int32,
        interest: DatabaseBrokerHealthTransportWaitInterest,
        deadline: UInt64,
        timeoutFailure: DatabaseBrokerHealthTransportFailure,
        bytesWritten: Int
    ) throws -> DatabaseBrokerHealthTransportWaitResult {
        while true {
            let now = dependencies.monotonicNanoseconds()
            guard now < deadline else {
                throw transportError(timeoutFailure, bytesWritten: bytesWritten)
            }
            let waitResult: DatabaseBrokerHealthTransportWaitResult
            do {
                waitResult = try dependencies.wait(
                    socketDescriptor,
                    interest,
                    deadline - now)
            } catch {
                throw transportError(.ioFailure, bytesWritten: bytesWritten)
            }
            switch waitResult {
            case .ready, .disconnected:
                return waitResult
            case .timedOut:
                throw transportError(timeoutFailure, bytesWritten: bytesWritten)
            case .interrupted:
                continue
            }
        }
    }

    private func addingBudget(_ budget: UInt64, to time: UInt64) -> UInt64 {
        let (deadline, overflow) = time.addingReportingOverflow(budget)
        return overflow ? UInt64.max : deadline
    }

    private func cappedDeadline(
        budget: UInt64,
        startingAt: UInt64,
        absoluteDeadline: UInt64?
    ) -> UInt64 {
        min(
            addingBudget(budget, to: startingAt),
            absoluteDeadline ?? UInt64.max)
    }

    private func transportError(
        _ failure: DatabaseBrokerHealthTransportFailure,
        bytesWritten: Int
    ) -> DatabaseBrokerHealthTransportError {
        DatabaseBrokerHealthTransportError(
            failure: failure,
            bytesWritten: bytesWritten)
    }
}

struct DatabaseBrokerHealthWriteOutcome {
    let bytesWritten: Int
    let sinkClosed: Bool
}

private enum DatabaseBrokerHealthSystemError: Error {
    case systemCallFailed
}

struct DatabaseBrokerHealthPOSIXReadAttempt: Sendable {
    let result: Int
    let errorCode: Int32
    let data: Data
}

struct DatabaseBrokerHealthPOSIXWriteAttempt: Sendable {
    let result: Int
    let errorCode: Int32
}

struct DatabaseBrokerHealthPOSIXIO: Sendable {
    let read:
        @Sendable (
            Int32,
            Int
        ) -> DatabaseBrokerHealthPOSIXReadAttempt
    let write:
        @Sendable (
            Int32,
            Data,
            Int
        ) -> DatabaseBrokerHealthPOSIXWriteAttempt

    init(
        read:
            @escaping @Sendable (
                Int32,
                Int
            ) -> DatabaseBrokerHealthPOSIXReadAttempt,
        write:
            @escaping @Sendable (
                Int32,
                Data,
                Int
            ) -> DatabaseBrokerHealthPOSIXWriteAttempt
    ) {
        self.read = read
        self.write = write
    }
}

final class DatabaseBrokerHealthAuthenticationWorker: @unchecked Sendable {
    static let shared = DatabaseBrokerHealthAuthenticationWorker(maximumConcurrentWork: 4)

    private let admission: DispatchSemaphore
    private let duplicateDescriptor:
        @Sendable (
            Int32,
            UInt64?,
            @Sendable () -> UInt64
        ) throws -> Int32
    private let closeDescriptor: @Sendable (Int32) -> Void
    private let queue = DispatchQueue(
        label: "com.pulkit.edith.database.health-authentication",
        qos: .userInitiated,
        attributes: .concurrent)

    init(
        maximumConcurrentWork: Int,
        duplicateDescriptor:
            @escaping @Sendable (
                Int32,
                UInt64?,
                @Sendable () -> UInt64
            ) throws -> Int32 = { socketDescriptor, deadlineNanoseconds, monotonicNanoseconds in
                try duplicateSocketDescriptor(
                    socketDescriptor,
                    deadlineNanoseconds: deadlineNanoseconds,
                    monotonicNanoseconds: monotonicNanoseconds)
            },
        closeDescriptor: @escaping @Sendable (Int32) -> Void = {
            _ = Darwin.close($0)
        }
    ) {
        admission = DispatchSemaphore(value: maximumConcurrentWork)
        self.duplicateDescriptor = duplicateDescriptor
        self.closeDescriptor = closeDescriptor
    }

    func authenticate(
        socketDescriptor: Int32,
        budgetNanoseconds: UInt64,
        deadlineNanoseconds: UInt64? = nil,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        operation: @escaping @Sendable (Int32) throws -> Void
    ) -> DatabaseBrokerHealthTransportAuthenticationResult {
        guard !deadlineExpired(deadlineNanoseconds, monotonicNanoseconds) else {
            return .timedOut
        }
        guard admission.wait(timeout: .now()) == .success else {
            return .timedOut
        }
        guard !deadlineExpired(deadlineNanoseconds, monotonicNanoseconds) else {
            admission.signal()
            return .timedOut
        }
        let ownedSocketDescriptor: Int32
        do {
            ownedSocketDescriptor = try duplicateDescriptor(
                socketDescriptor,
                deadlineNanoseconds,
                monotonicNanoseconds)
        } catch {
            admission.signal()
            return deadlineExpired(deadlineNanoseconds, monotonicNanoseconds)
                ? .timedOut
                : .systemFailure
        }
        guard !deadlineExpired(deadlineNanoseconds, monotonicNanoseconds) else {
            closeDescriptor(ownedSocketDescriptor)
            admission.signal()
            return .timedOut
        }
        let completion = DispatchSemaphore(value: 0)
        let result = DatabaseBrokerHealthAuthenticationResultBox()
        queue.async {
            defer {
                self.closeDescriptor(ownedSocketDescriptor)
                self.admission.signal()
                completion.signal()
            }
            do {
                try operation(ownedSocketDescriptor)
                result.set(.authenticated)
            } catch let error as DatabaseBrokerPeerAuthenticationError {
                result.set(.failed(error))
            } catch {
                result.set(.systemFailure)
            }
        }
        let completionDeadline: DispatchTime
        if let deadlineNanoseconds {
            guard monotonicNanoseconds() < deadlineNanoseconds else {
                return .timedOut
            }
            completionDeadline = DispatchTime(uptimeNanoseconds: deadlineNanoseconds)
        } else {
            let boundedBudget = Int(min(budgetNanoseconds, UInt64(Int.max)))
            completionDeadline = .now() + .nanoseconds(boundedBudget)
        }
        guard completion.wait(timeout: completionDeadline) == .success else {
            return .timedOut
        }
        guard !deadlineExpired(deadlineNanoseconds, monotonicNanoseconds) else {
            return .timedOut
        }
        return result.value ?? .systemFailure
    }

    private func deadlineExpired(
        _ deadlineNanoseconds: UInt64?,
        _ monotonicNanoseconds: @Sendable () -> UInt64
    ) -> Bool {
        guard let deadlineNanoseconds else { return false }
        return monotonicNanoseconds() >= deadlineNanoseconds
    }

    private static func duplicateSocketDescriptor(
        _ socketDescriptor: Int32,
        deadlineNanoseconds: UInt64?,
        monotonicNanoseconds: @Sendable () -> UInt64
    ) throws -> Int32 {
        while true {
            if let deadlineNanoseconds,
                monotonicNanoseconds() >= deadlineNanoseconds
            {
                throw DatabaseBrokerHealthSystemError.systemCallFailed
            }
            let duplicatedDescriptor = fcntl(socketDescriptor, F_DUPFD_CLOEXEC, 0)
            if duplicatedDescriptor >= 0 {
                return duplicatedDescriptor
            }
            if errno != EINTR {
                throw DatabaseBrokerHealthSystemError.systemCallFailed
            }
        }
    }
}

private final class DatabaseBrokerHealthAuthenticationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: DatabaseBrokerHealthTransportAuthenticationResult?

    var value: DatabaseBrokerHealthTransportAuthenticationResult? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: DatabaseBrokerHealthTransportAuthenticationResult) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

extension DatabaseBrokerHealthTransportDependencies {
    static func live(
        authenticator: DatabaseBrokerPeerAuthenticator,
        authenticationWorker: DatabaseBrokerHealthAuthenticationWorker = .shared,
        posixIO: DatabaseBrokerHealthPOSIXIO = .live
    ) -> DatabaseBrokerHealthTransportDependencies {
        let monotonicNanoseconds: @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
        return DatabaseBrokerHealthTransportDependencies(
            monotonicNanoseconds: monotonicNanoseconds,
            authenticatePeer: {
                socketDescriptor,
                budgetNanoseconds,
                deadlineNanoseconds in
                authenticationWorker.authenticate(
                    socketDescriptor: socketDescriptor,
                    budgetNanoseconds: budgetNanoseconds,
                    deadlineNanoseconds: deadlineNanoseconds,
                    monotonicNanoseconds: monotonicNanoseconds
                ) { authenticatedSocketDescriptor in
                    try authenticator.authenticatePeer(
                        socketDescriptor: authenticatedSocketDescriptor)
                }
            },
            wait: { socketDescriptor, interest, maximumWaitNanoseconds in
                try waitForSocket(
                    socketDescriptor: socketDescriptor,
                    interest: interest,
                    maximumWaitNanoseconds: maximumWaitNanoseconds)
            },
            read: { socketDescriptor, maximumByteCount, deadlineNanoseconds in
                try readFromSocket(
                    socketDescriptor: socketDescriptor,
                    maximumByteCount: maximumByteCount,
                    posixIO: posixIO,
                    deadlineNanoseconds: deadlineNanoseconds,
                    monotonicNanoseconds: monotonicNanoseconds)
            },
            write: { socketDescriptor, data, offset, deadlineNanoseconds in
                try writeToSocket(
                    socketDescriptor: socketDescriptor,
                    data: data,
                    offset: offset,
                    posixIO: posixIO,
                    deadlineNanoseconds: deadlineNanoseconds,
                    monotonicNanoseconds: monotonicNanoseconds)
            })
    }

    private static func waitForSocket(
        socketDescriptor: Int32,
        interest: DatabaseBrokerHealthTransportWaitInterest,
        maximumWaitNanoseconds: UInt64
    ) throws -> DatabaseBrokerHealthTransportWaitResult {
        let requestedEvents: Int16 =
            interest == .readable
            ? Int16(POLLIN)
            : Int16(POLLOUT)
        var descriptor = pollfd(
            fd: socketDescriptor,
            events: requestedEvents,
            revents: 0)
        let result = Darwin.poll(
            &descriptor,
            1,
            pollTimeoutMilliseconds(maximumWaitNanoseconds))
        if result == 0 {
            return .timedOut
        }
        if result < 0 {
            if errno == EINTR {
                return .interrupted
            }
            throw DatabaseBrokerHealthSystemError.systemCallFailed
        }
        if descriptor.revents & requestedEvents != 0 {
            return .ready
        }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            return .disconnected
        }
        throw DatabaseBrokerHealthSystemError.systemCallFailed
    }

    static func readFromSocket(
        socketDescriptor: Int32,
        maximumByteCount: Int,
        posixIO: DatabaseBrokerHealthPOSIXIO,
        deadlineNanoseconds: UInt64? = nil,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> DatabaseBrokerHealthTransportReadResult {
        while true {
            if let deadlineNanoseconds,
                monotonicNanoseconds() >= deadlineNanoseconds
            {
                return .timedOut
            }
            let attempt = posixIO.read(socketDescriptor, maximumByteCount)
            if attempt.result > 0 {
                guard attempt.data.count == attempt.result else {
                    throw DatabaseBrokerHealthSystemError.systemCallFailed
                }
                return .bytes(attempt.data)
            }
            if attempt.result == 0 {
                return .endOfFile
            }
            if attempt.errorCode == EINTR {
                continue
            }
            if attempt.errorCode == EAGAIN || attempt.errorCode == EWOULDBLOCK {
                return .wouldBlock
            }
            if attempt.errorCode == ECONNRESET || attempt.errorCode == ENOTCONN {
                return .endOfFile
            }
            throw DatabaseBrokerHealthSystemError.systemCallFailed
        }
    }

    static func writeToSocket(
        socketDescriptor: Int32,
        data: Data,
        offset: Int,
        posixIO: DatabaseBrokerHealthPOSIXIO,
        deadlineNanoseconds: UInt64? = nil,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> DatabaseBrokerHealthTransportWriteResult {
        while true {
            if let deadlineNanoseconds,
                monotonicNanoseconds() >= deadlineNanoseconds
            {
                return .timedOut
            }
            let attempt = posixIO.write(socketDescriptor, data, offset)
            if attempt.result > 0 {
                return .bytes(attempt.result)
            }
            if attempt.result == 0 {
                return .bytes(0)
            }
            if attempt.errorCode == EINTR {
                continue
            }
            if attempt.errorCode == EAGAIN || attempt.errorCode == EWOULDBLOCK {
                return .wouldBlock
            }
            if attempt.errorCode == EPIPE || attempt.errorCode == ECONNRESET
                || attempt.errorCode == ENOTCONN
            {
                return .sinkClosed
            }
            throw DatabaseBrokerHealthSystemError.systemCallFailed
        }
    }

    private static func pollTimeoutMilliseconds(_ nanoseconds: UInt64) -> Int32 {
        let milliseconds = nanoseconds / 1_000_000
        let roundedMilliseconds = milliseconds + (nanoseconds % 1_000_000 == 0 ? 0 : 1)
        return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
    }
}

extension DatabaseBrokerHealthPOSIXIO {
    static let live = DatabaseBrokerHealthPOSIXIO(
        read: { socketDescriptor, maximumByteCount in
            var buffer = [UInt8](repeating: 0, count: maximumByteCount)
            let result = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    socketDescriptor,
                    rawBuffer.baseAddress,
                    maximumByteCount)
            }
            return DatabaseBrokerHealthPOSIXReadAttempt(
                result: result,
                errorCode: result < 0 ? errno : 0,
                data: result > 0 ? Data(buffer.prefix(result)) : Data())
        },
        write: { socketDescriptor, data, offset in
            let result = data.withUnsafeBytes { rawBuffer in
                Darwin.send(
                    socketDescriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    data.count - offset,
                    MSG_NOSIGNAL)
            }
            return DatabaseBrokerHealthPOSIXWriteAttempt(
                result: result,
                errorCode: result < 0 ? errno : 0)
        })
}
