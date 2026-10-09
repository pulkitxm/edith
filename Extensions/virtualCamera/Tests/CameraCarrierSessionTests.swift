import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor
private final class CarrierBrokerProbe: CameraSystemExtensionSubmitting {
    struct Request {
        let operation: CameraSystemExtensionOperation
        let completion: @MainActor (CameraSystemExtensionEvent) -> Void
    }
    var requests: [Request] = []
    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void
    ) {
        requests.append(.init(operation: operation, completion: completion))
    }
}

@Suite(.serialized) @MainActor struct CameraCarrierSessionTests {
    @Test func framesHandleFragmentationAndRejectOversizedOrEmptyMessages() throws {
        let request = CameraCarrierRequest(token: UUID(), operation: .status)
        let encoded = try CameraCarrierFrames.encode(request)
        var frames = CameraCarrierFrames()
        #expect(try frames.append(Data(encoded.prefix(4))).isEmpty)
        let values = try frames.append(Data(encoded.dropFirst(4)))
        #expect(values.count == 1)
        #expect(
            try JSONDecoder().decode(CameraCarrierRequest.self, from: values[0]).token
                == request.token)
        #expect(throws: (any Error).self) { try frames.append(Data([10])) }
        #expect(throws: (any Error).self) {
            try frames.append(Data(repeating: 1, count: CameraCarrierFrames.maximumBytes + 1))
        }
        #expect(throws: (any Error).self) {
            try CameraCarrierFrames.encode(
                String(repeating: "a", count: CameraCarrierFrames.maximumBytes))
        }
        var partial = CameraCarrierFrames()
        #expect(
            try partial.append(Data(repeating: 1, count: CameraCarrierFrames.maximumBytes - 1))
                .isEmpty)
        #expect(throws: (any Error).self) { try partial.append(Data([1, 1])) }
    }

    @Test func disconnectDrainsCancelledActivationAndProviderBeforeReleasingLease() async throws {
        let broker = CarrierBrokerProbe()
        var providerExited = false
        var released = false
        var exited = false
        var replies: [CameraCarrierReply] = []
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker,
            providerExited: { providerExited })
        let session = CameraCarrierSession(
            controller: controller, send: { replies.append(try decode($0)) }, prepareMicrophone: {},
            releaseResources: {
                #expect(providerExited)
                #expect(!controller.ownsProvider)
                released = true
            }, exited: { exited = true })
        session.receive(try request(.activate))
        try await wait { broker.requests.count == 1 }
        session.disconnect()
        #expect(!released)
        broker.requests[0].completion(.approvalRequired)
        broker.requests[0].completion(.completed)
        try await wait { broker.requests.count == 2 }
        #expect(broker.requests[1].operation == .deactivate)
        #expect(!released)
        providerExited = true
        broker.requests[1].completion(.completed)
        try await wait { session.released }
        #expect(released && exited)
        let count = replies.count
        broker.requests[0].completion(.completed)
        session.receive(try request(.activate))
        #expect(replies.count == count)
        #expect(!controller.ownsProvider)
    }

    @Test func rebootPendingKeepsLeaseAndDoesNotResubmitCleanup() async throws {
        let broker = CarrierBrokerProbe()
        var releases = 0
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker, initiallyActive: true,
            providerExited: {
                Issue.record("Pending reboot does not prove provider exit"); return true
            })
        let session = CameraCarrierSession(
            controller: controller, send: { _ in }, prepareMicrophone: {},
            releaseResources: { releases += 1 },
            exited: { Issue.record("Pending reboot must keep carrier ownership") })
        session.disconnect()
        try await wait { broker.requests.count == 1 }
        broker.requests[0].completion(.restartRequired)
        try await Task.sleep(for: .milliseconds(5))
        session.retryDisconnectedCleanup()
        await #expect(throws: (any Error).self) { try await controller.activate() }
        await #expect(throws: (any Error).self) { try await controller.deactivate() }
        #expect(broker.requests.count == 1)
        #expect(controller.phase == .restartRequired)
        #expect(controller.ownsProvider)
        #expect(releases == 0 && !session.released)
    }

    @Test func rejectedProviderExitRetainsLeaseAndSafeRetryCanComplete() async throws {
        let broker = CarrierBrokerProbe()
        var providerExited = false
        var releases = 0
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker, initiallyActive: true,
            providerExited: { providerExited })
        let session = CameraCarrierSession(
            controller: controller, send: { _ in }, prepareMicrophone: {},
            releaseResources: { releases += 1 }, exited: {})
        session.disconnect()
        try await wait { broker.requests.count == 1 }
        broker.requests[0].completion(.completed)
        try await wait { !controller.pendingRequest }
        #expect(controller.ownsProvider && !session.released)
        providerExited = true
        session.retryDisconnectedCleanup()
        try await wait { broker.requests.count == 2 }
        broker.requests[1].completion(.completed)
        try await wait { session.released }
        #expect(releases == 1)
        session.retryDisconnectedCleanup()
        #expect(broker.requests.count == 2)
    }

    @Test func cancellationTokenCompensatesLateActivation() async throws {
        let broker = CarrierBrokerProbe()
        var replies: [CameraCarrierReply] = []
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker, providerExited: { true })
        let session = CameraCarrierSession(
            controller: controller, send: { replies.append(try decode($0)) }, prepareMicrophone: {},
            releaseResources: {}, exited: {})
        let token = UUID()
        session.receive(
            try CameraCarrierFrames.encode(CameraCarrierRequest(token: token, operation: .activate))
        )
        try await wait { broker.requests.count == 1 }
        session.receive(
            try CameraCarrierFrames.encode(
                CameraCarrierRequest(token: UUID(), operation: .cancel, cancelledToken: token)))
        try await wait { replies.contains { $0.token == token && $0.error != nil } }
        broker.requests[0].completion(.completed)
        try await wait { broker.requests.count == 2 }
        broker.requests[1].completion(.completed)
        try await wait { !controller.pendingRequest }
        #expect(!controller.ownsProvider)
        session.disconnect()
        try await wait { session.released }
    }

    @Test func malformedRequestsAndBrokenReplyPipesTriggerCleanup() async throws {
        for bytes in [
            Data("{invalid}\n".utf8),
            try CameraCarrierFrames.encode(CameraCarrierRequest(token: UUID(), operation: .cancel)),
            Data(),
        ] {
            let controller = CameraSystemExtensionController(
                identifier: "org.example.fixture.camera", broker: CarrierBrokerProbe(),
                providerExited: { true })
            let session = CameraCarrierSession(
                controller: controller, send: { _ in }, prepareMicrophone: {}, releaseResources: {},
                exited: {})
            session.receive(bytes)
            try await wait { session.released }
            #expect(session.disconnected)
        }
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: CarrierBrokerProbe(),
            providerExited: { true })
        let session = CameraCarrierSession(
            controller: controller, send: { _ in throw CocoaError(.fileWriteUnknown) },
            prepareMicrophone: {}, releaseResources: {}, exited: {})
        session.receive(try request(.status))
        try await wait { session.released }
        #expect(session.disconnected)
    }

    @Test func pendingRequestsStayBoundedWhileCancellationRemainsAvailable() async throws {
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: CarrierBrokerProbe(),
            providerExited: { true })
        var replies: [CameraCarrierReply] = []
        let session = CameraCarrierSession(
            controller: controller, send: { replies.append(try decode($0)) },
            prepareMicrophone: { try await Task.sleep(for: .seconds(60)) }, releaseResources: {},
            exited: {})
        let tokens = (0..<8).map { _ in UUID() }
        for token in tokens {
            session.receive(
                try CameraCarrierFrames.encode(
                    CameraCarrierRequest(token: token, operation: .microphonePrepare)))
        }
        let cancel = UUID()
        session.receive(
            try CameraCarrierFrames.encode(
                CameraCarrierRequest(token: cancel, operation: .cancel, cancelledToken: tokens[0])))
        #expect(!session.disconnected)
        #expect(replies.contains { $0.token == cancel })
        session.receive(try request(.microphonePrepare))
        try await wait { session.released }
        #expect(session.disconnected)
    }

    @Test func microphoneRetirementKeepsCarrierOwnedUntilRestart() async throws {
        let broker = CarrierBrokerProbe()
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker, providerExited: { true })
        var replies: [CameraCarrierReply] = []
        var releases = 0
        let session = CameraCarrierSession(
            controller: controller, send: { replies.append(try decode($0)) }, prepareMicrophone: {},
            prepareDisableResources: {
                throw CameraCarrierRestartRequired(
                    message: "Restart macOS to release the loaded microphone driver.")
            }, releaseResources: { releases += 1 },
            exited: { Issue.record("A pending driver must not release its carrier") })
        let token = UUID()
        session.receive(
            try CameraCarrierFrames.encode(
                CameraCarrierRequest(token: token, operation: .deactivate)))
        try await wait { replies.contains { $0.token == token } }
        let reply = try #require(replies.first { $0.token == token })
        #expect(reply.status.phase == "restartRequired")
        #expect(reply.status.ownsProvider)
        #expect(reply.error?.contains("Restart") == true)
        session.disconnect(); session.retryDisconnectedCleanup()
        try await Task.sleep(for: .milliseconds(5))
        #expect(releases == 0 && !session.released)
        #expect(broker.requests.isEmpty)
    }

    @Test func microphoneFailureIsBoundedAndCannotActivateProvider() async throws {
        let broker = CarrierBrokerProbe()
        var replies: [CameraCarrierReply] = []
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker, providerExited: { true })
        let session = CameraCarrierSession(
            controller: controller, send: { replies.append(try decode($0)) },
            prepareMicrophone: {
                throw NSError(
                    domain: "Fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 4096)])
            }, releaseResources: {}, exited: {})
        let token = UUID()
        session.receive(
            try CameraCarrierFrames.encode(
                CameraCarrierRequest(token: token, operation: .microphonePrepare)))
        try await wait { replies.contains { $0.token == token } }
        let reply = try #require(replies.first { $0.token == token })
        #expect(reply.error?.count == 1024)
        #expect(broker.requests.isEmpty && !controller.ownsProvider)
        session.disconnect()
        try await wait { session.released }
    }

    private func request(_ operation: CameraCarrierOperation) throws -> Data {
        try CameraCarrierFrames.encode(CameraCarrierRequest(token: UUID(), operation: operation))
    }
    private func decode(_ data: Data) throws -> CameraCarrierReply {
        try JSONDecoder().decode(CameraCarrierReply.self, from: Data(data.dropLast()))
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Carrier lifecycle did not reach its expected state")
        throw CancellationError()
    }
}
