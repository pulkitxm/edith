import Darwin
import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerHealthTransportTestError: Error {
    case fixtureFailure
}

private final class DatabaseBrokerHealthTransportSystemStub: @unchecked Sendable {
    struct ReadStep {
        let advanceNanoseconds: UInt64
        let result: DatabaseBrokerHealthTransportReadResult
    }

    struct WriteStep {
        let advanceNanoseconds: UInt64
        let result: DatabaseBrokerHealthTransportWriteResult
    }

    struct WaitStep {
        let advanceNanoseconds: UInt64
        let result: DatabaseBrokerHealthTransportWaitResult
    }

    enum Call: Equatable {
        case authenticate(Int32, UInt64)
        case wait(Int32, DatabaseBrokerHealthTransportWaitInterest, UInt64)
        case read(Int32, Int)
        case write(Int32, Int)
    }

    var now: UInt64 = 0
    var authenticationResult = DatabaseBrokerHealthTransportAuthenticationResult.authenticated
    var readSteps: [ReadStep] = []
    var writeSteps: [WriteStep] = []
    var waitSteps: [WaitStep] = []
    var calls: [Call] = []
    var writtenData = Data()

    func dependencies() -> DatabaseBrokerHealthTransportDependencies {
        DatabaseBrokerHealthTransportDependencies(
            monotonicNanoseconds: { self.now },
            authenticatePeer: { socketDescriptor, budgetNanoseconds in
                self.calls.append(.authenticate(socketDescriptor, budgetNanoseconds))
                return self.authenticationResult
            },
            wait: { socketDescriptor, interest, maximumWaitNanoseconds in
                self.calls.append(.wait(socketDescriptor, interest, maximumWaitNanoseconds))
                guard !self.waitSteps.isEmpty else {
                    self.now += maximumWaitNanoseconds
                    return .timedOut
                }
                let step = self.waitSteps.removeFirst()
                self.now += step.advanceNanoseconds
                return step.result
            },
            read: { socketDescriptor, maximumByteCount in
                self.calls.append(.read(socketDescriptor, maximumByteCount))
                guard !self.readSteps.isEmpty else {
                    return .endOfFile
                }
                let step = self.readSteps.removeFirst()
                self.now += step.advanceNanoseconds
                return step.result
            },
            write: { socketDescriptor, data, offset in
                self.calls.append(.write(socketDescriptor, offset))
                let step: WriteStep
                if self.writeSteps.isEmpty {
                    step = WriteStep(
                        advanceNanoseconds: 0,
                        result: .bytes(data.count - offset))
                } else {
                    step = self.writeSteps.removeFirst()
                }
                self.now += step.advanceNanoseconds
                if case .bytes(let byteCount) = step.result,
                    byteCount > 0,
                    byteCount <= data.count - offset
                {
                    self.writtenData.append(data[offset..<(offset + byteCount)])
                }
                return step.result
            })
    }
}

private final class DatabaseBrokerHealthPOSIXIOStub: @unchecked Sendable {
    var readAttempts: [DatabaseBrokerHealthPOSIXReadAttempt] = []
    var writeAttempts: [DatabaseBrokerHealthPOSIXWriteAttempt] = []
    var readCallCount = 0
    var writeCallCount = 0

    func posixIO() -> DatabaseBrokerHealthPOSIXIO {
        DatabaseBrokerHealthPOSIXIO(
            read: { _, _ in
                self.readCallCount += 1
                guard !self.readAttempts.isEmpty else {
                    return DatabaseBrokerHealthPOSIXReadAttempt(
                        result: -1,
                        errorCode: EIO,
                        data: Data())
                }
                return self.readAttempts.removeFirst()
            },
            write: { _, _, _ in
                self.writeCallCount += 1
                guard !self.writeAttempts.isEmpty else {
                    return DatabaseBrokerHealthPOSIXWriteAttempt(
                        result: -1,
                        errorCode: EIO)
                }
                return self.writeAttempts.removeFirst()
            })
    }
}

private final class DatabaseBrokerHealthLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func update(_ operation: (inout Value) -> Void) {
        lock.lock()
        operation(&storedValue)
        lock.unlock()
    }
}

private enum DatabaseBrokerHealthTransportFixtures {
    static let requestID = UUID(uuidString: "FB12C5CB-BB3D-459F-A9A4-CA0993B3F6C0")!
    static let otherRequestID = UUID(uuidString: "55344A96-9386-457D-BEA4-37ED09D5DA90")!
    static let brokerInstanceID = UUID(uuidString: "B9F60570-5594-4347-A0B6-87E68618297D")!

    static func request(
        requestID: UUID = requestID,
        sequence: UInt64 = 0
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest> {
        DatabaseBrokerEnvelope(
            requestID: requestID,
            sequence: sequence,
            kind: .request,
            payload: DatabaseBrokerHealthRequest())
    }

    static func response(
        requestID: UUID = requestID,
        isReady: Bool = true
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerHealthResponse> {
        DatabaseBrokerEnvelope(
            requestID: requestID,
            sequence: 0,
            kind: .response,
            payload: DatabaseBrokerHealthResponse(
                brokerInstanceID: brokerInstanceID,
                isReady: isReady))
    }

    static func requestFrame(
        requestID: UUID = requestID,
        sequence: UInt64 = 0
    ) throws -> Data {
        try DatabaseBrokerFrameCodec.encode(
            request(requestID: requestID, sequence: sequence),
            stream: .requests)
    }

    static func responseFrame(
        requestID: UUID = requestID,
        isReady: Bool = true
    ) throws -> Data {
        try DatabaseBrokerFrameCodec.encode(
            response(requestID: requestID, isReady: isReady),
            stream: .responses)
    }

    static func transportError<T>(
        _ operation: () throws -> T
    ) -> DatabaseBrokerHealthTransportError? {
        do {
            _ = try operation()
            Issue.record("Expected transport error")
            return nil
        } catch let error as DatabaseBrokerHealthTransportError {
            return error
        } catch {
            Issue.record("Unexpected error type")
            return nil
        }
    }

    static func nonblockingSocketPair() throws -> [Int32] {
        var socketDescriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &socketDescriptors) == 0 else {
            throw DatabaseBrokerHealthTransportTestError.fixtureFailure
        }
        do {
            for socketDescriptor in socketDescriptors {
                let flags = fcntl(socketDescriptor, F_GETFL)
                guard
                    flags >= 0,
                    fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
                else {
                    throw DatabaseBrokerHealthTransportTestError.fixtureFailure
                }
            }
        } catch {
            for socketDescriptor in socketDescriptors where socketDescriptor >= 0 {
                _ = close(socketDescriptor)
            }
            throw error
        }
        return socketDescriptors
    }

    static func writeEntireFrame(
        _ frame: Data,
        socketDescriptor: Int32
    ) throws {
        var offset = 0
        while offset < frame.count {
            let result = frame.withUnsafeBytes { rawBuffer in
                Darwin.send(
                    socketDescriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    frame.count - offset,
                    MSG_NOSIGNAL)
            }
            if result > 0 {
                offset += result
                continue
            }
            if result < 0, errno == EINTR {
                continue
            }
            throw DatabaseBrokerHealthTransportTestError.fixtureFailure
        }
    }

    static func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}

@Suite struct DatabaseBrokerHealthTransportTests {
    @Test func clientAuthenticatesBeforeWritingAndReadsAtMost64KiB() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.readSteps = [
            .init(
                advanceNanoseconds: 0,
                result: .bytes(try DatabaseBrokerHealthTransportFixtures.responseFrame()))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let response = try transport.requestHealth(
            socketDescriptor: 40,
            requestID: DatabaseBrokerHealthTransportFixtures.requestID)

        #expect(response.brokerInstanceID == DatabaseBrokerHealthTransportFixtures.brokerInstanceID)
        #expect(response.isReady)
        #expect(
            system.calls.first
                == .authenticate(
                    40,
                    DatabaseBrokerHealthTransport.authenticationBudgetNanoseconds))
        let firstWriteIndex = try #require(system.calls.firstIndex(of: .write(40, 0)))
        let firstReadIndex = try #require(
            system.calls.firstIndex(
                of: .read(40, DatabaseBrokerHealthTransport.maximumReadBytes)))
        #expect(firstWriteIndex < firstReadIndex)
        #expect(
            system.calls.compactMap { call -> Int? in
                guard case .read(_, let maximumByteCount) = call else {
                    return nil
                }
                return maximumByteCount
            } == [64 * 1_024, 64 * 1_024])
    }

    @Test func serverAuthenticatesBeforeFragmentedPrefixAndPayloadReads() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let requestFrame = try DatabaseBrokerHealthTransportFixtures.requestFrame()
        system.readSteps = requestFrame.map {
            .init(
                advanceNanoseconds: 0,
                result: .bytes(Data([$0])))
        }
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let result = try transport.serveHealth(socketDescriptor: 41) { _ in
            DatabaseBrokerHealthResponse(
                brokerInstanceID: DatabaseBrokerHealthTransportFixtures.brokerInstanceID,
                isReady: true)
        }

        #expect(result.requestID == DatabaseBrokerHealthTransportFixtures.requestID)
        #expect(result.disposition == .sent)
        #expect(result.responseBytesWritten == system.writtenData.count)
        #expect(system.calls.first == .authenticate(41, 2_000_000_000))
        let firstReadIndex = try #require(
            system.calls.firstIndex(
                of: .read(41, DatabaseBrokerHealthTransport.maximumReadBytes)))
        let firstWriteIndex = try #require(system.calls.firstIndex(of: .write(41, 0)))
        #expect(firstReadIndex < firstWriteIndex)

        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerHealthResponse>(
            stream: .responses)
        let responses = try decoder.append(system.writtenData)
        try decoder.finish()
        #expect(responses.count == 1)
        #expect(responses.first?.requestID == DatabaseBrokerHealthTransportFixtures.requestID)
    }

    @Test func realNonblockingSocketPairCompletesMutuallyAuthenticatedHealthRoundTrip() async throws
    {
        let socketDescriptors = try DatabaseBrokerHealthTransportFixtures.nonblockingSocketPair()
        defer {
            _ = close(socketDescriptors[0])
            _ = close(socketDescriptors[1])
        }
        let transport = try DatabaseBrokerHealthTransport()
        let serverTask = Task.detached {
            try transport.serveHealth(socketDescriptor: socketDescriptors[0]) { _ in
                DatabaseBrokerHealthResponse(
                    brokerInstanceID: DatabaseBrokerHealthTransportFixtures.brokerInstanceID,
                    isReady: true)
            }
        }

        let response = try transport.requestHealth(
            socketDescriptor: socketDescriptors[1],
            requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        let serverResult = try await serverTask.value

        #expect(response.brokerInstanceID == DatabaseBrokerHealthTransportFixtures.brokerInstanceID)
        #expect(response.isReady)
        #expect(serverResult.disposition == .sent)
        #expect(serverResult.responseBytesWritten > 0)
    }

    @Test func authenticationTimeoutPreventsAllFrameIO() {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.authenticationResult = .timedOut
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(socketDescriptor: 42)
        }

        #expect(
            error
                == DatabaseBrokerHealthTransportError(
                    failure: .authenticationTimedOut,
                    bytesWritten: 0))
        #expect(error?.isReplaySafe == true)
        #expect(system.calls == [.authenticate(42, 2_000_000_000)])
    }

    @Test func liveAuthenticationWorkerOwnsDuplicateAcrossTimeoutAndRetainsAdmission() {
        let authenticatedDescriptor = DatabaseBrokerHealthLockedValue<Int32?>(nil)
        let closedDescriptors = DatabaseBrokerHealthLockedValue<[Int32]>([])
        let descriptorClosed = DispatchSemaphore(value: 0)
        let worker = DatabaseBrokerHealthAuthenticationWorker(
            maximumConcurrentWork: 1,
            duplicateDescriptor: { $0 + 1_000 },
            closeDescriptor: { socketDescriptor in
                closedDescriptors.update { $0.append(socketDescriptor) }
                descriptorClosed.signal()
            })
        let release = DispatchSemaphore(value: 0)
        let start = DispatchTime.now().uptimeNanoseconds

        let firstResult = worker.authenticate(
            socketDescriptor: 43,
            budgetNanoseconds: 20_000_000
        ) { socketDescriptor in
            authenticatedDescriptor.update { $0 = socketDescriptor }
            release.wait()
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let secondResult = worker.authenticate(
            socketDescriptor: 44,
            budgetNanoseconds: 20_000_000
        ) { _ in }

        #expect(firstResult == .timedOut)
        #expect(secondResult == .timedOut)
        #expect(closedDescriptors.value.isEmpty)
        #expect(elapsed < 500_000_000)

        release.signal()
        #expect(descriptorClosed.wait(timeout: .now() + .seconds(1)) == .success)

        #expect(authenticatedDescriptor.value == 1_043)
        #expect(closedDescriptors.value == [1_043])
    }

    @Test func typedAuthenticationFailureSurvivesWorkerAndTransport() {
        let closedDescriptors = DatabaseBrokerHealthLockedValue<[Int32]>([])
        let worker = DatabaseBrokerHealthAuthenticationWorker(
            maximumConcurrentWork: 1,
            duplicateDescriptor: { $0 + 2_000 },
            closeDescriptor: { socketDescriptor in
                closedDescriptors.update { $0.append(socketDescriptor) }
            })
        let workerResult = worker.authenticate(
            socketDescriptor: 45,
            budgetNanoseconds: 1_000_000_000
        ) { _ in
            throw DatabaseBrokerPeerAuthenticationError.uniqueIdentifierMismatch
        }

        let system = DatabaseBrokerHealthTransportSystemStub()
        system.authenticationResult = .failed(.uniqueIdentifierMismatch)
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())
        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(socketDescriptor: 46)
        }

        #expect(workerResult == .failed(.uniqueIdentifierMismatch))
        #expect(closedDescriptors.value == [2_045])
        #expect(error?.failure == .authenticationFailed(.uniqueIdentifierMismatch))
        #expect(error?.bytesWritten == 0)
    }

    @Test func authenticationWorkerFailsClosedWhenDescriptorDuplicationFails() {
        let operationCalled = DatabaseBrokerHealthLockedValue(false)
        let worker = DatabaseBrokerHealthAuthenticationWorker(
            maximumConcurrentWork: 1,
            duplicateDescriptor: { _ in
                throw DatabaseBrokerHealthTransportTestError.fixtureFailure
            },
            closeDescriptor: { _ in })

        let result = worker.authenticate(
            socketDescriptor: 47,
            budgetNanoseconds: 1_000_000_000
        ) { _ in
            operationCalled.update { $0 = true }
        }

        #expect(result == .systemFailure)
        #expect(!operationCalled.value)
    }

    @Test func frameDeadlineStartsWhenFirstPrefixByteArrives() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let frame = try DatabaseBrokerHealthTransportFixtures.responseFrame()
        system.readSteps = [
            .init(
                advanceNanoseconds: 4_500_000_000,
                result: .bytes(Data(frame.prefix(1)))),
            .init(
                advanceNanoseconds: 4_900_000_000,
                result: .bytes(Data(frame.dropFirst()))),
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let response = try transport.requestHealth(
            socketDescriptor: 45,
            requestID: DatabaseBrokerHealthTransportFixtures.requestID)

        #expect(response.isReady)
        #expect(system.now == 9_400_000_000)
    }

    @Test func frameDeadlineExpiresFiveSecondsAfterFirstPrefixByte() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let frame = try DatabaseBrokerHealthTransportFixtures.responseFrame()
        system.readSteps = [
            .init(
                advanceNanoseconds: 1_000_000_000,
                result: .bytes(Data(frame.prefix(1)))),
            .init(advanceNanoseconds: 0, result: .wouldBlock),
        ]
        system.waitSteps = [
            .init(advanceNanoseconds: 5_000_000_000, result: .timedOut)
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())
        let requestFrame = try DatabaseBrokerHealthTransportFixtures.requestFrame()

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 46,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .readTimedOut)
        #expect(error?.bytesWritten == requestFrame.count)
        #expect(error?.isReplaySafe == false)
        #expect(system.calls.contains(.wait(46, .readable, 5_000_000_000)))
    }

    @Test(arguments: [2, 8])
    func rejectsTruncatedEOFAtPrefixAndPayloadBoundaries(byteCount: Int) throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let frame = try DatabaseBrokerHealthTransportFixtures.responseFrame()
        system.readSteps = [
            .init(
                advanceNanoseconds: 0,
                result: .bytes(Data(frame.prefix(byteCount)))),
            .init(advanceNanoseconds: 0, result: .endOfFile),
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 47,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .truncatedFrame)
        #expect(error?.isReplaySafe == false)
    }

    @Test func rejectsMultipleTerminalResponsesInOneRead() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let frame = try DatabaseBrokerHealthTransportFixtures.responseFrame()
        system.readSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(frame + frame))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 48,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .multipleFrames)
        #expect(error?.isReplaySafe == false)
    }

    @Test func rejectsSecondTerminalResponseAvailableInFollowingRead() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let frame = try DatabaseBrokerHealthTransportFixtures.responseFrame()
        system.readSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(frame)),
            .init(advanceNanoseconds: 0, result: .bytes(frame)),
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 48,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .multipleFrames)
        #expect(error?.isReplaySafe == false)
    }

    @Test func rejectsMismatchedResponseCorrelationAfterRequestWrite() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.readSteps = [
            .init(
                advanceNanoseconds: 0,
                result: .bytes(
                    try DatabaseBrokerHealthTransportFixtures.responseFrame(
                        requestID: DatabaseBrokerHealthTransportFixtures.otherRequestID)))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())
        let requestFrame = try DatabaseBrokerHealthTransportFixtures.requestFrame()

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 49,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .responseValidationFailure(.requestIDMismatch))
        #expect(error?.bytesWritten == requestFrame.count)
        #expect(error?.isReplaySafe == false)
    }

    @Test func rejectsReadLargerThan64KiB() {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.readSteps = [
            .init(
                advanceNanoseconds: 0,
                result: .bytes(Data(repeating: 0, count: 64 * 1_024 + 1)))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 50,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .readLimitExceeded)
        #expect(error?.isReplaySafe == false)
    }

    @Test func rejectsOversizedDeclaredResponseBeforePayloadAllocation() {
        let system = DatabaseBrokerHealthTransportSystemStub()
        var declaredLength = UInt32(
            DatabaseBrokerProtocol.responseMaximumFrameBytes + 1
        ).bigEndian
        let prefix = withUnsafeBytes(of: &declaredLength) { Data($0) }
        system.readSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(prefix))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(
                socketDescriptor: 51,
                requestID: DatabaseBrokerHealthTransportFixtures.requestID)
        }

        #expect(error?.failure == .protocolFailure(.frameTooLarge))
        #expect(error?.isReplaySafe == false)
    }

    @Test func partialRequestWriteMakesProgressTimeoutNonReplaySafe() {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.writeSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(3)),
            .init(advanceNanoseconds: 0, result: .wouldBlock),
        ]
        system.waitSteps = [
            .init(advanceNanoseconds: 5_000_000_000, result: .timedOut)
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(socketDescriptor: 52)
        }

        #expect(error?.failure == .writeProgressTimedOut)
        #expect(error?.bytesWritten == 3)
        #expect(error?.isReplaySafe == false)
        #expect(system.calls.contains(.write(52, 3)))
        #expect(system.calls.contains(.wait(52, .writable, 5_000_000_000)))
    }

    @Test func requestWriteTimeoutBeforeProgressRemainsReplaySafe() {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.writeSteps = [
            .init(advanceNanoseconds: 0, result: .wouldBlock)
        ]
        system.waitSteps = [
            .init(advanceNanoseconds: 5_000_000_000, result: .timedOut)
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(socketDescriptor: 53)
        }

        #expect(error?.failure == .writeProgressTimedOut)
        #expect(error?.bytesWritten == 0)
        #expect(error?.isReplaySafe == true)
    }

    @Test func eachPartialWriteResetsFiveSecondProgressDeadline() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let responseFrame = try DatabaseBrokerHealthTransportFixtures.responseFrame()
        system.writeSteps = [
            .init(advanceNanoseconds: 4_000_000_000, result: .bytes(1)),
            .init(advanceNanoseconds: 0, result: .wouldBlock),
            .init(advanceNanoseconds: 400_000_000, result: .bytes(Int.max)),
        ]
        system.waitSteps = [
            .init(advanceNanoseconds: 4_500_000_000, result: .ready)
        ]
        system.readSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(responseFrame))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        system.writeSteps[2] = .init(
            advanceNanoseconds: 400_000_000,
            result: .bytes(
                try DatabaseBrokerHealthTransportFixtures.requestFrame().count - 1))
        let response = try transport.requestHealth(
            socketDescriptor: 54,
            requestID: DatabaseBrokerHealthTransportFixtures.requestID)

        #expect(response.isReady)
        #expect(system.now == 8_900_000_000)
    }

    @Test func zeroByteSendOfNonemptyFrameIsInvalidProgress() {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.writeSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(0))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.requestHealth(socketDescriptor: 55)
        }

        #expect(error?.failure == .invalidIOProgress)
        #expect(error?.bytesWritten == 0)
        #expect(error?.isReplaySafe == true)
    }

    @Test func invalidRequestIsNeverAdmittedAndWritesNoResponse() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.readSteps = [
            .init(
                advanceNanoseconds: 0,
                result: .bytes(
                    try DatabaseBrokerHealthTransportFixtures.requestFrame(sequence: 1)))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())
        let handlerCalled = DatabaseBrokerHealthLockedValue(false)

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.serveHealth(socketDescriptor: 56) { _ in
                handlerCalled.update { $0 = true }
                return DatabaseBrokerHealthResponse(isReady: true)
            }
        }

        #expect(error?.failure == .requestValidationFailure(.invalidSequence))
        #expect(!handlerCalled.value)
        #expect(
            !system.calls.contains { call in
                if case .write = call {
                    return true
                }
                return false
            })
    }

    @Test func multipleRequestsAreNeverAdmitted() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        let frame = try DatabaseBrokerHealthTransportFixtures.requestFrame()
        system.readSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(frame + frame))
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())
        let handlerCalled = DatabaseBrokerHealthLockedValue(false)

        let error = DatabaseBrokerHealthTransportFixtures.transportError {
            try transport.serveHealth(socketDescriptor: 57) { _ in
                handlerCalled.update { $0 = true }
                return DatabaseBrokerHealthResponse(isReady: true)
            }
        }

        #expect(error?.failure == .multipleFrames)
        #expect(!handlerCalled.value)
        #expect(system.writtenData.isEmpty)
    }

    @Test func admittedRequestCompletesWorkWhenResponseSinkDropsAfterPartialWrite() throws {
        let system = DatabaseBrokerHealthTransportSystemStub()
        system.readSteps = [
            .init(
                advanceNanoseconds: 0,
                result: .bytes(try DatabaseBrokerHealthTransportFixtures.requestFrame()))
        ]
        system.writeSteps = [
            .init(advanceNanoseconds: 0, result: .bytes(2)),
            .init(advanceNanoseconds: 0, result: .sinkClosed),
        ]
        let transport = DatabaseBrokerHealthTransport(dependencies: system.dependencies())
        let handlerCallCount = DatabaseBrokerHealthLockedValue(0)

        let result = try transport.serveHealth(socketDescriptor: 58) { _ in
            handlerCallCount.update { $0 += 1 }
            return DatabaseBrokerHealthResponse(isReady: true)
        }

        #expect(handlerCallCount.value == 1)
        #expect(result.disposition == .responseSinkDropped)
        #expect(result.responseBytesWritten == 2)
    }

    @Test func clientEOFAfterAdmissionDropsOnlyServerResponseSink() async throws {
        let socketDescriptors = try DatabaseBrokerHealthTransportFixtures.nonblockingSocketPair()
        let serverSocket = socketDescriptors[0]
        let clientSocket = socketDescriptors[1]
        defer { _ = close(serverSocket) }
        let transport = try DatabaseBrokerHealthTransport()
        let handlerEntered = DispatchSemaphore(value: 0)
        let allowHandlerReturn = DispatchSemaphore(value: 0)
        let serverTask = Task.detached {
            try transport.serveHealth(socketDescriptor: serverSocket) { _ in
                handlerEntered.signal()
                allowHandlerReturn.wait()
                return DatabaseBrokerHealthResponse(
                    brokerInstanceID: DatabaseBrokerHealthTransportFixtures.brokerInstanceID,
                    isReady: true)
            }
        }
        try DatabaseBrokerHealthTransportFixtures.writeEntireFrame(
            DatabaseBrokerHealthTransportFixtures.requestFrame(),
            socketDescriptor: clientSocket)
        let handlerDidEnter = await DatabaseBrokerHealthTransportFixtures.wait(
            for: handlerEntered,
            timeout: .now() + .seconds(2))
        try #require(handlerDidEnter)

        _ = shutdown(clientSocket, SHUT_RDWR)
        _ = close(clientSocket)
        allowHandlerReturn.signal()
        let result = try await serverTask.value

        #expect(result.disposition == .responseSinkDropped)
        #expect(result.requestID == DatabaseBrokerHealthTransportFixtures.requestID)
    }

    @Test func livePOSIXReadAndWriteRetryEINTR() throws {
        let readStub = DatabaseBrokerHealthPOSIXIOStub()
        readStub.readAttempts = [
            .init(result: -1, errorCode: EINTR, data: Data()),
            .init(result: 3, errorCode: 0, data: Data([1, 2, 3])),
        ]
        let readResult = try DatabaseBrokerHealthTransportDependencies.readFromSocket(
            socketDescriptor: 60,
            maximumByteCount: 64 * 1_024,
            posixIO: readStub.posixIO())

        let writeStub = DatabaseBrokerHealthPOSIXIOStub()
        writeStub.writeAttempts = [
            .init(result: -1, errorCode: EINTR),
            .init(result: 2, errorCode: 0),
        ]
        let writeResult = try DatabaseBrokerHealthTransportDependencies.writeToSocket(
            socketDescriptor: 61,
            data: Data([1, 2]),
            offset: 0,
            posixIO: writeStub.posixIO())

        #expect(readResult == .bytes(Data([1, 2, 3])))
        #expect(readStub.readCallCount == 2)
        #expect(writeResult == .bytes(2))
        #expect(writeStub.writeCallCount == 2)
    }

    @Test(arguments: [ECONNRESET, ENOTCONN])
    func livePOSIXNormalizesDisconnectedReadAndWrite(errorCode: Int32) throws {
        let readStub = DatabaseBrokerHealthPOSIXIOStub()
        readStub.readAttempts = [
            .init(result: -1, errorCode: errorCode, data: Data())
        ]
        let readResult = try DatabaseBrokerHealthTransportDependencies.readFromSocket(
            socketDescriptor: 62,
            maximumByteCount: 64 * 1_024,
            posixIO: readStub.posixIO())

        let writeStub = DatabaseBrokerHealthPOSIXIOStub()
        writeStub.writeAttempts = [
            .init(result: -1, errorCode: errorCode)
        ]
        let writeResult = try DatabaseBrokerHealthTransportDependencies.writeToSocket(
            socketDescriptor: 63,
            data: Data([1]),
            offset: 0,
            posixIO: writeStub.posixIO())

        #expect(readResult == .endOfFile)
        #expect(writeResult == .sinkClosed)
    }

    @Test func livePOSIXReportsZeroByteSendAsInvalidProgress() throws {
        let stub = DatabaseBrokerHealthPOSIXIOStub()
        stub.writeAttempts = [
            .init(result: 0, errorCode: 0)
        ]

        let result = try DatabaseBrokerHealthTransportDependencies.writeToSocket(
            socketDescriptor: 64,
            data: Data([1]),
            offset: 0,
            posixIO: stub.posixIO())

        #expect(result == .bytes(0))
    }
}
