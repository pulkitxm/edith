import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor
private final class CameraBrokerProbe: CameraSystemExtensionSubmitting {
    struct Request {
        let operation: CameraSystemExtensionOperation
        let identifier: String
        let completion: @MainActor (CameraSystemExtensionEvent) -> Void
    }
    var requests: [Request] = []
    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void
    ) {
        requests.append(.init(operation: operation, identifier: identifier, completion: completion))
    }
}

@Suite(.serialized) @MainActor struct CameraSystemExtensionControllerTests {
    @Test func activationAndDisableWaitForActualProviderExit() async throws {
        let broker = CameraBrokerProbe()
        var probes = 0
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker,
            providerExited: {
                probes += 1; return true
            })
        let activation = Task { try await controller.activate() }
        try await wait { broker.requests.count == 1 }
        #expect(controller.phase == .activating)
        #expect(controller.ownsProvider)
        broker.requests[0].completion(.approvalRequired)
        #expect(controller.phase == .awaitingApproval)
        broker.requests[0].completion(.completed)
        try await activation.value
        #expect(controller.phase == .active)
        let deactivation = Task { try await controller.deactivate() }
        try await wait { broker.requests.count == 2 }
        #expect(broker.requests[1].operation == .deactivate)
        #expect(probes == 0)
        broker.requests[1].completion(.completed)
        try await deactivation.value
        #expect(probes == 1)
        #expect(!controller.ownsProvider)
        #expect(!controller.pendingRequest)
        #expect(controller.phase == .stopped)
    }

    @Test func rebootPendingRetainsProviderOwnershipAndRejectsDisable() async throws {
        let broker = CameraBrokerProbe()
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker,
            initiallyActive: true,
            providerExited: {
                Issue.record("Reboot pending must not imply exit"); return true
            })
        let deactivation = Task { try await controller.deactivate() }
        try await wait { broker.requests.count == 1 }
        broker.requests[0].completion(.restartRequired)
        await #expect(throws: (any Error).self) { try await deactivation.value }
        #expect(controller.ownsProvider)
        #expect(controller.phase == .restartRequired)
    }

    @Test func failedActivationAndStaleCallbacksCannotPublishSuccess() async throws {
        let broker = CameraBrokerProbe()
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker,
            providerExited: { true })
        let activation = Task { try await controller.activate() }
        try await wait { broker.requests.count == 1 }
        broker.requests[0].completion(.failed("Synthetic profile rejection"))
        await #expect(throws: (any Error).self) { try await activation.value }
        #expect(controller.phase == .failed("Synthetic profile rejection"))
        #expect(!controller.ownsProvider)
        broker.requests[0].completion(.completed)
        #expect(!controller.ownsProvider)
        #expect(broker.requests.count == 1)
    }

    @Test func cancelledActivationDrainsLateApprovalAndDeactivatesBeforeRelease() async throws {
        let broker = CameraBrokerProbe()
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker,
            providerExited: { true })
        let activation = Task { try await controller.activate() }
        try await wait { broker.requests.count == 1 }
        activation.cancel()
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(controller.ownsProvider)
        #expect(controller.pendingRequest)
        broker.requests[0].completion(.approvalRequired)
        broker.requests[0].completion(.completed)
        #expect(broker.requests.count == 2)
        #expect(broker.requests[1].operation == .deactivate)
        #expect(controller.ownsProvider)
        broker.requests[1].completion(.completed)
        try await wait { !controller.pendingRequest }
        #expect(!controller.ownsProvider)
        broker.requests[0].completion(.completed)
        #expect(!controller.ownsProvider)
    }

    @Test func providerExitFailureRetainsOwnershipAndAllowsSafeRetry() async throws {
        let broker = CameraBrokerProbe()
        var exited = false
        let controller = CameraSystemExtensionController(
            identifier: "org.example.fixture.camera", broker: broker,
            initiallyActive: true, providerExited: { exited })
        let first = Task { try await controller.deactivate() }
        try await wait { broker.requests.count == 1 }
        broker.requests[0].completion(.completed)
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(controller.ownsProvider)
        exited = true
        let second = Task { try await controller.deactivate() }
        try await wait { broker.requests.count == 2 }
        broker.requests[1].completion(.completed)
        try await second.value
        #expect(!controller.ownsProvider)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Camera request did not reach its expected lifecycle state")
        throw CancellationError()
    }
}
