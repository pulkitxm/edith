import AppKit
import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor @Suite(.serialized) struct VirtualCameraObservationTests {
    @Test func injectedNotificationsInstallOnceAndStopWithEngine() async {
        let center = CameraObservationCenter()
        let hardware = FakeCameraHardware()
        var requestedCenters = 0
        let engine = makeEngine(hardware: hardware) {
            requestedCenters += 1
            return center
        }
        engine.start()
        engine.start()
        #expect(requestedCenters == 1)
        #expect(center.installed == 2)
        #expect(center.removed == 0)
        #expect(!engine.snapshot().obsAvailable)
        hardware.devices = [40: VirtualCameraOBS.deviceUID]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        #expect(engine.snapshot().obsAvailable)
        await engine.finishShutdown()
        #expect(center.removed == 2)
        hardware.devices = [:]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        #expect(engine.snapshot().obsAvailable)
        await engine.finishShutdown()
        #expect(requestedCenters == 1)
        #expect(center.removed == 2)
        #expect(hardware.started.isEmpty)
    }

    @Test func unavailableObservationDoesNotSubscribeOrDiscoverHardware() async {
        let hardware = FakeCameraHardware()
        var requestedCenters = 0
        let engine = makeEngine(hardware: hardware) {
            requestedCenters += 1
            return nil
        }
        engine.start()
        #expect(requestedCenters == 1)
        #expect(!engine.snapshot().obsAvailable)
        #expect(engine.snapshot().sources.isEmpty)
        #expect(!engine.streaming)
        #expect(hardware.started.isEmpty)
        await engine.finishShutdown()
        engine.start()
        #expect(requestedCenters == 1)
        #expect(engine.isStopped)
        #expect(hardware.started.isEmpty)
    }

    private func makeEngine(
        hardware: FakeCameraHardware,
        notifications: @escaping () -> NotificationCenter?
    ) -> VirtualCameraEngine {
        var state = VirtualCameraState(output: .obs)
        state.privacy = .stopped
        return VirtualCameraEngine(
            edithSink: VirtualCameraSink(deviceUID: "synthetic-unavailable", hardware: hardware),
            obsSink: VirtualCameraSink(deviceUID: VirtualCameraOBS.deviceUID, hardware: hardware),
            state: state,
            environment: VirtualCameraEngineEnvironment(
                authorization: { .denied }, obsRunning: { false },
                frontmostApplication: { nil }, sources: { [] },
                applicationNotifications: notifications),
            previewBus: VirtualCameraPreviewBus(
                file: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "camera-observation-\(UUID().uuidString).bin"), unlinkOnClose: true))
    }
}

private final class CameraObservationCenter: NotificationCenter, @unchecked Sendable {
    private(set) var installed = 0
    private(set) var removed = 0

    override func addObserver(
        forName name: NSNotification.Name?, object: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        installed += 1
        return super.addObserver(forName: name, object: object, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}
