import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchCameraTests {
    private func request(_ operation: NotchCameraRequest.Operation, deviceID: String? = nil)
        -> NotchCameraRequest
    {
        .init(
            identity: .init(ownershipID: UUID(), generation: UUID()), displayID: 42,
            presentationID: UUID(), operation: operation, deviceID: deviceID)
    }

    @Test func permissionSelectionFramesAndShutdownUseOnlyOwnedInjectedHardware() async throws {
        let hardware = CameraFixtureHardware()
        let engine = NotchCameraEngine(hardware: hardware)
        #expect(try engine.state().devices.isEmpty)
        await #expect(throws: (any Error).self) { try await engine.execute(request(.start)) }
        _ = try await engine.execute(request(.permission))
        #expect(hardware.starts == ["front"])
        let first = try #require(hardware.frames.first)
        first(Data([1, 2, 3]))
        await Task.yield(); await Task.yield()
        #expect(try engine.state().frame == Data([1, 2, 3]))
        _ = try await engine.execute(request(.select, deviceID: "rear"))
        #expect(hardware.starts == ["front", "rear"])
        #expect(hardware.stops == 1)
        first(Data([9]))
        await Task.yield(); await Task.yield()
        #expect(try engine.state().frame == nil)
        let current = try #require(hardware.frames.last)
        current(Data([4, 5]))
        await Task.yield(); await Task.yield()
        #expect(try engine.state().selectedID == "rear")
        #expect(try engine.state().frame == Data([4, 5]))
        await #expect(throws: (any Error).self) {
            try await engine.execute(request(.select, deviceID: "outside"))
        }
        current(Data(repeating: 0, count: 524289))
        await Task.yield(); await Task.yield()
        #expect(try engine.state().frame == Data([4, 5]))
        await engine.shutdownAndWait()
        #expect(hardware.stops == 2)
        current(Data([8]))
        await Task.yield()
        #expect(throws: (any Error).self) { try engine.state() }
    }

    @Test func checkedPanelRejectsHiddenInactiveAndStaleCameraAndCollapseStopsCapture() async throws
    {
        let hardware = CameraFixtureHardware()
        hardware.authorization = AVAuthorizationStatus.authorized.rawValue
        let fixture = try NotchPanelFixture(cameraFactory: { NotchCameraEngine(hardware: hardware) }
        )
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        var command = NotchCameraRequest(
            identity: try #require(fixture.engine.identity), displayID: 42,
            presentationID: fixture.presentation, operation: .start)
        await #expect(throws: (any Error).self) { try await fixture.engine.camera(command) }
        #expect(hardware.starts.isEmpty)
        controller.expand(on: 42, preferredTab: .camera)
        _ = try await fixture.engine.camera(command)
        #expect(hardware.starts == ["front"])
        command = .init(
            identity: command.identity, displayID: 42, presentationID: UUID(), operation: .start)
        await #expect(throws: (any Error).self) { try await fixture.engine.camera(command) }
        let presenter = ExtensionSharedState(
            root: fixture.root, namespace: fixture.id, owner: "presenter")
        try presenter.publish(["active": "1", "blurCamera": "1"])
        controller.synchronize()
        #expect(try fixture.engine.cameraEngine?.state().frame == nil)
        let valid = NotchCameraRequest(
            identity: try #require(fixture.engine.identity), displayID: 42,
            presentationID: fixture.presentation, operation: .start)
        await #expect(throws: (any Error).self) { try await fixture.engine.camera(valid) }
        try presenter.publish(["active": "0"])
        controller.synchronize()
        _ = try await fixture.engine.camera(valid)
        try fixture.engine.stopScene(
            .init(
                identity: try #require(fixture.engine.identity), displayID: 42,
                presentationID: fixture.presentation))
        #expect(try fixture.engine.cameraEngine?.state().frame == nil)
        controller.collapseNow()
        await fixture.engine.cameraEngine?.shutdownAndWait()
        #expect(hardware.stops == 2)
    }

    @Test func switchActionWaitsForOwnedFrameReadAndIsNotDropped() async throws {
        let hardware = CameraFixtureHardware()
        hardware.authorization = AVAuthorizationStatus.authorized.rawValue
        let engine = NotchCameraEngine(hardware: hardware)
        var pending: CheckedContinuation<Void, Never>?
        var hold = false
        let client = NotchCameraClient(
            namespace: "notch-camera-queue-" + UUID().uuidString, presentationID: UUID()
        ) { operation, id in
            if operation == .read, hold { await withCheckedContinuation { pending = $0 } }
            return try await engine.execute(self.request(operation, deviceID: id))
        }
        await client.load()
        #expect(client.state?.selectedID == "front")
        hold = true
        client.perform(.read)
        await Task.yield()
        let release = try #require(pending)
        client.cycle()
        hold = false
        release.resume()
        await client.drain()
        #expect(client.state?.selectedID == "rear")
        #expect(hardware.starts == ["front", "rear"])
        #expect(client.error == nil)
        client.stop()
        await engine.shutdownAndWait()
    }

    @Test func originalPromptRendersOffscreenAndLateCancelledReadCannotReturn() async throws {
        var pending: CheckedContinuation<Data, Error>?
        var operations: [NotchCameraRequest.Operation] = []
        let client = NotchCameraClient(
            namespace: "notch-camera-fixture-" + UUID().uuidString, presentationID: UUID()
        ) { operation, _ in
            operations.append(operation)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        client.perform(.read)
        await Task.yield()
        let waiting = try #require(pending)
        let state = NotchCameraState(
            authorization: AVAuthorizationStatus.notDetermined.rawValue, devices: [],
            selectedID: nil, frame: nil, error: nil)
        waiting.resume(returning: try JSONEncoder().encode(state))
        await client.drain()
        let view = NSHostingView(
            rootView: NotchRemoteCameraTab(model: client).environment(
                \.automaticViewActionsEnabled, false))
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 260)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        #expect(operations == [.read])
        client.perform(.read)
        await Task.yield()
        let late = try #require(pending)
        client.stop()
        late.resume(returning: try JSONEncoder().encode(state))
        await Task.yield(); await Task.yield()
        #expect(client.state == nil)
        #expect(client.image == nil)
    }
}

@MainActor private final class CameraFixtureHardware: NotchCameraHardware {
    var authorization = AVAuthorizationStatus.notDetermined.rawValue
    var devices: [NotchCameraDevice] {
        [.init(id: "front", name: "Synthetic front"), .init(id: "rear", name: "Synthetic rear")]
    }
    var starts: [String] = []
    var frames: [@Sendable (Data) -> Void] = []
    var stops = 0
    func permission() async -> Bool {
        authorization = AVAuthorizationStatus.authorized.rawValue; return true
    }
    func start(deviceID: String?, frame: @escaping @Sendable (Data) -> Void) async throws {
        starts.append(deviceID ?? ""); frames.append(frame)
    }
    func stop() async { stops += 1 }
    func privacy() throws { Issue.record("Native privacy opening is forbidden in fixture tests") }
}
