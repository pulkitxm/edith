import AppKit
import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchPanelCoordinatorTests {
    @Test func boundedLongPollAndOwnedPointerAndMeasurementUseCurrentScreen() async throws {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { coordinator.attachedSceneCount == 2 && fixture.transport.waiting }
        #expect(coordinator.panelCount == 1)
        #expect(fixture.presented == 1)
        #expect(fixture.transport.waitTimeout == 25)
        #expect(fixture.transport.operationTimeouts.allSatisfy { $0 <= 30 })
        coordinator.pointer(
            displayID: 1, globalPoint: CGPoint(x: 450, y: 690), buttons: 1,
            option: true, draggingFiles: false)
        let native = try #require(fixture.leases.first { $0.request.extensionID == "music" })
        native.measuredHeight?(232)
        await settle {
            fixture.transport.pointers.count == 1 && fixture.transport.measures.count == 1
        }
        let pointer = try #require(fixture.transport.pointers.first)
        #expect(pointer.x == 450 && pointer.y == 90)
        #expect(pointer.presentationID == fixture.screens.first?.presentationID)
        #expect(pointer.identity.ownershipID == coordinator.ownershipID)
        #expect(pointer.buttons == 1 && pointer.option)
        let measure = try #require(fixture.transport.measures.first)
        #expect(measure.height == 232 && measure.revision == 1)
        #expect(measure.slotID == fixture.transport.current?.states.first?.slots.first?.id)
        coordinator.pointer(
            displayID: 99, globalPoint: .zero, buttons: 1, option: false, draggingFiles: false)
        native.measuredHeight?(.infinity)
        try await coordinator.stop()
        #expect(!fixture.transport.waiting)
        #expect(fixture.transport.detached == 1)
        #expect(coordinator.attachedSceneCount == 0 && coordinator.pendingCleanupCount == 0)
        #expect(fixture.leases.allSatisfy { $0.closed })
    }

    @Test func nativeApprovalFailureIsPublishedIntoOriginalChrome() async throws {
        let fixture = NotchCoordinatorFixture()
        fixture.failMusicApproval = true
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { fixture.transport.measures.count == 1 }
        let failure = try #require(fixture.transport.measures.first)
        #expect(failure.error?.contains("Approve this extension") == true)
        #expect(failure.slotID == fixture.transport.current?.states.first?.slots.first?.id)
        #expect(failure.presentationID == fixture.screens.first?.presentationID)
        #expect(coordinator.attachedSceneCount == 1)
        #expect(fixture.leases.allSatisfy { $0.request.extensionID == "notchShelf" })
        try await coordinator.stop()
    }

    @Test func unchangedLongPollTimeoutDoesNotRecreateOriginalScenes() async throws {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { coordinator.attachedSceneCount == 2 && fixture.transport.waiting }
        fixture.now = fixture.now.advanced(by: .seconds(25))
        fixture.transport.respond()
        await settle { fixture.transport.waitCalls == 2 && fixture.transport.waiting }
        #expect(fixture.leases.count == 2)
        #expect(fixture.presented == 1)
        try await coordinator.stop()
    }

    @Test func disableWithdrawsNativeScenesBeforeConfirmedPanelDetach() async throws {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { coordinator.attachedSceneCount == 2 }
        fixture.environment.activeVersions = [:]
        coordinator.synchronize()
        #expect(coordinator.attachedSceneCount == 0)
        await settle { !fixture.transport.waiting }
        try await coordinator.stop()
        #expect(fixture.transport.detached == 1)
        #expect(fixture.leases.allSatisfy { $0.closed })
        #expect(coordinator.panelCount == 0 && coordinator.pendingCleanupCount == 0)
    }

    @Test func immediateUnchangedReplyCannotCreateARequestLoop() async throws {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { coordinator.attachedSceneCount == 2 && fixture.transport.waiting }
        fixture.transport.respond()
        await settle { coordinator.failure != nil && coordinator.attachedSceneCount == 0 }
        #expect(fixture.transport.waitCalls == 1)
        #expect(!fixture.transport.waiting)
        try await coordinator.stop()
    }

    @Test func failedDetachRetainsControlOwnershipAndRetryDoesNotRestorePanels() async throws {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { coordinator.attachedSceneCount == 2 }
        fixture.transport.failDetach = true
        await #expect(throws: HostWorkerError.rejected) { try await coordinator.stop() }
        #expect(coordinator.attachedSceneCount == 0)
        #expect(coordinator.pendingCleanupCount == 1)
        #expect(coordinator.failure != nil)
        #expect(fixture.leases.allSatisfy { $0.closed })
        fixture.transport.failDetach = false
        try await coordinator.stop()
        #expect(coordinator.panelCount == 0 && coordinator.pendingCleanupCount == 0)
        #expect(coordinator.failure == nil)
        #expect(fixture.presented == 1)
        await #expect(throws: HostNotchPanelError.invalidState) {
            try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        }
    }

    @Test func lostAttachReplyRecoversOnlyExactOwnershipAndConfirmsDetach() async throws {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        fixture.transport.loseFirstAttachReply = true
        let error = await #expect(throws: ExtensionPeerError.self) {
            try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        }
        if case .timedOut? = error {} else { Issue.record("Expected an owned attach timeout.") }
        #expect(fixture.transport.attachCalls == 2 && fixture.transport.detached == 1)
        #expect(fixture.transport.current?.identity.ownershipID == coordinator.ownershipID)
        #expect(coordinator.panelCount == 0 && coordinator.pendingCleanupCount == 0)
        #expect(fixture.leases.isEmpty && fixture.presented == 0)
    }

    @Test func invalidSecondDisplayRejectsWholeBatchBeforeAnySceneStarts() async throws {
        let fixture = NotchCoordinatorFixture()
        fixture.screens.append(
            .init(
                display: .init(
                    id: 2, frame: CGRect(x: 1024, y: 0, width: 1440, height: 900),
                    collapsedSize: CGSize(width: 150, height: 28)), isBuiltin: false))
        fixture.transport.invalidSecondDisplay = true
        let coordinator = fixture.coordinator()
        await #expect(throws: HostNotchPanelError.invalidState) {
            try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        }
        #expect(fixture.leases.isEmpty && fixture.presented == 0)
        #expect(fixture.transport.detached == 1)
    }

    @Test func crossDisplaySceneBudgetIsValidatedWithoutDroppingCards() async throws {
        let fixture = NotchCoordinatorFixture()
        fixture.screens.append(
            .init(
                display: .init(
                    id: 2, frame: CGRect(x: 1024, y: 0, width: 1440, height: 900),
                    collapsedSize: CGSize(width: 150, height: 28)), isBuiltin: false))
        fixture.environment.reservedProviderScenes = ["music": 15]
        let coordinator = fixture.coordinator()
        await #expect(throws: HostNotchPanelError.capacityExceeded) {
            try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        }
        #expect(fixture.leases.isEmpty && fixture.presented == 0)
        #expect(fixture.transport.detached == 1)
    }

    @Test func releaseAndSceneStopFailuresRetainOwnershipBeforeDetachAndRetryAfterDisable()
        async throws
    {
        let fixture = NotchCoordinatorFixture()
        let coordinator = fixture.coordinator()
        try await coordinator.start(version: "1.0.0", screens: fixture.screens)
        await settle { coordinator.attachedSceneCount == 2 }
        fixture.failSceneRelease = true
        fixture.environment.activeVersions = [:]
        await #expect(throws: HostWorkerError.rejected) { try await coordinator.stop() }
        #expect(fixture.transport.detached == 0)
        #expect(fixture.transport.stoppedScenes.isEmpty)
        #expect(coordinator.pendingCleanupCount >= 2)
        fixture.failSceneRelease = false
        fixture.transport.failSceneStop = true
        await #expect(throws: HostWorkerError.rejected) { try await coordinator.stop() }
        #expect(fixture.leases.allSatisfy { $0.closed })
        #expect(fixture.transport.detached == 0)
        #expect(coordinator.pendingCleanupCount >= 1)
        fixture.transport.failSceneStop = false
        try await coordinator.stop()
        #expect(fixture.transport.stoppedScenes == Set(fixture.screens.map(\.presentationID)))
        #expect(fixture.transport.detached == 1)
        #expect(coordinator.pendingCleanupCount == 0)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class NotchCoordinatorFixture {
    let transport = NotchCoordinatorTransport()
    var screens: [HostNotchPanelScreen]
    var environment: HostNotchPanelEnvironment
    var leases: [HostNotchSceneLease] = []
    var presented = 0
    var failSceneRelease = false
    var failMusicApproval = false
    var now = ContinuousClock.now
    init() {
        _ = TestWindowHost.application
        let fixture = HostNotchStateFixture()
        screens = [.init(display: fixture.display, isBuiltin: true)]
        environment = .init(
            activeVersions: ["notchShelf": "1.0.0", "music": "1.0.0"],
            layout: .init(tiles: [fixture.tile]))
        transport.tile = fixture.tile
    }
    func coordinator() -> HostNotchPanelCoordinator {
        HostNotchPanelCoordinator(
            invoke: transport.invoke, environment: { [self] in environment },
            create: { [self] request in
                if failMusicApproval, request.extensionID == "music" {
                    throw HostRemoteAvailabilityError.approvalRequired
                }
                let controller = NSViewController()
                controller.view = NSView()
                let lease = HostNotchSceneLease(
                    request: request, controller: controller,
                    update: { _, _, _ in },
                    release: { [self] in
                        if failSceneRelease { throw HostWorkerError.rejected }
                        transport.released.insert(request.presentationID)
                    })
                leases.append(lease)
                return lease
            },
            present: { [self] panel in
                #expect(!panel.isVisible)
                presented += 1
            }, now: { [self] in now })
    }
}

@MainActor
private final class NotchCoordinatorTransport {
    var released = Set<UUID>()
    var stoppedScenes = Set<UUID>()
    var failSceneStop = false
    var tile = SurfaceTile(.music)
    var current: HostNotchPanelBatch?
    var waitCalls = 0
    var attachCalls = 0
    var detached = 0
    var waitTimeout = 0.0
    var operationTimeouts: [Double] = []
    var pointers: [HostNotchPanelPointer] = []
    var measures: [HostNotchPanelMeasure] = []
    var failDetach = false
    var loseFirstAttachReply = false
    var invalidSecondDisplay = false
    private var attachedRequest: HostNotchPanelAttach?
    private var wait: CheckedContinuation<Data, any Error>?
    var waiting: Bool { wait != nil }

    func invoke(_ command: String, payload: Data, timeout: Double) async throws -> Data {
        operationTimeouts.append(timeout)
        #expect(payload.count <= HostNotchPanelState.maximumBytes)
        let decoder = JSONDecoder()
        switch command {
        case "notch.panel.attach":
            attachCalls += 1
            let request = try decoder.decode(HostNotchPanelAttach.self, from: payload)
            if let attachedRequest {
                #expect(attachedRequest == request)
            } else {
                attachedRequest = request
            }
            if current == nil {
                current = HostNotchPanelBatch(
                    identity: .init(ownershipID: request.ownershipID, generation: UUID()),
                    revision: 1,
                    states: request.displays.map { display in
                        let slot = HostNotchNativeSlot(
                            id: UUID(), providerID: "music", providerVersion: "1.0.0",
                            kind: .card, tile: tile,
                            rectangle: .init(
                                x: invalidSecondDisplay && display.displayID == 2 ? -1 : 222,
                                y: 68, width: 280, height: 160))
                        return HostNotchPanelState(
                            contractVersion: 1, ownershipID: request.ownershipID,
                            version: request.version, revision: 1, displayID: display.displayID,
                            presentationID: display.presentationID, phase: .expanded,
                            activeTab: "home", shapeWidth: 580, shapeHeight: 400, visible: true,
                            acceptsPointer: true, acceptsKeyFocus: false, slots: [slot])
                    })
            }
            #expect(current?.identity.ownershipID == request.ownershipID)
            if loseFirstAttachReply && attachCalls == 1 { throw ExtensionPeerError.timedOut }
            return try JSONEncoder().encode(current)
        case "notch.panel.wait":
            let request = try decoder.decode(HostNotchPanelWait.self, from: payload)
            #expect(request.identity == current?.identity)
            #expect(request.revision == current?.revision)
            waitCalls += 1; waitTimeout = request.timeout
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        wait = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelWait() }
            }
        case "notch.panel.pointer":
            pointers.append(try decoder.decode(HostNotchPanelPointer.self, from: payload))
        case "notch.panel.measure":
            measures.append(try decoder.decode(HostNotchPanelMeasure.self, from: payload))
        case "notch.panel.scene.stop":
            let request = try decoder.decode(HostNotchPanelSceneStop.self, from: payload)
            #expect(request.identity == current?.identity)
            #expect(released.contains(request.presentationID))
            if failSceneStop { throw HostWorkerError.rejected }
            stoppedScenes.insert(request.presentationID)
        case "notch.panel.detach":
            #expect(
                try decoder.decode(HostNotchPanelIdentity.self, from: payload) == current?.identity)
            if failDetach { throw HostWorkerError.rejected }
            detached += 1
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }
    func respond() {
        guard let wait else { return }
        self.wait = nil
        do { wait.resume(returning: try JSONEncoder().encode(current)) } catch {
            wait.resume(throwing: error)
        }
    }
    private func cancelWait() {
        wait?.resume(throwing: CancellationError()); wait = nil
    }
}
