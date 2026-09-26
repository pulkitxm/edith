import AppKit
import CoreImage
import CoreMediaIO
import CoreVideo
import EdithCameraSupport
import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }

    var now: TimeInterval { lock.withLock { value } }

    func set(_ next: TimeInterval) {
        lock.withLock { value = next }
    }
}

enum VirtualCameraFixtures {
    static let context = CIContext()

    static func quadrants(width: Int = 640, height: Int = 360) -> CVPixelBuffer? {
        guard let buffer = VirtualCameraPlaceholder.makeBuffer(width: width, height: height)
        else { return nil }
        let image = VirtualCameraRendererTests.quadrants(
            width: CGFloat(width), height: CGFloat(height))
        context.render(
            image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)
    {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }
}

@Suite(.serialized) struct VirtualCameraPipelineTests {
    let output = CGSize(width: 320, height: 180)

    @Test func processedFramesMatchTheOutputSizeAndCount() throws {
        let pipeline = VirtualCameraPipeline(state: VirtualCameraState(), outputSize: output)
        let input = try #require(VirtualCameraFixtures.quadrants())
        let first = try #require(pipeline.process(input, at: 1))
        #expect(CVPixelBufferGetWidth(first) == 320)
        #expect(CVPixelBufferGetHeight(first) == 180)
        #expect(CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(first) != nil)
        _ = pipeline.process(input, at: 1.03)
        let statistics = pipeline.statistics
        #expect(statistics.framesRendered == 2)
        #expect(statistics.framesPerSecond == 2)
        let topLeft = VirtualCameraFixtures.pixel(first, x: 20, y: 20)
        #expect(topLeft.red > 240 && topLeft.green < 15)
    }

    @Test func outputSizeChangesRebuildTheBufferPool() throws {
        let pipeline = VirtualCameraPipeline(state: VirtualCameraState(), outputSize: output)
        let input = try #require(VirtualCameraFixtures.quadrants())
        pipeline.update(outputSize: CGSize(width: 1280, height: 720), frameRate: 30)
        let frame = try #require(pipeline.process(input, at: 1))
        #expect(CVPixelBufferGetWidth(frame) == 1280)
    }

    @Test func sceneChangesGlideWhenTransitionsAreSmooth() throws {
        let clock = ManualClock(100)
        var state = VirtualCameraState()
        let wide = state.scenes[0]
        state.scenes.append(
            VirtualCameraScene(
                name: "Corner",
                composition: VirtualCameraComposition(
                    framing: VirtualCameraFraming(zoom: 2.2, centerX: 0.25, centerY: 0.25))))
        _ = try VirtualCameraSceneLibrary.apply(wide.name, in: &state)
        let pipeline = VirtualCameraPipeline(
            state: state, outputSize: output, clock: { clock.now })
        let input = try #require(VirtualCameraFixtures.quadrants())
        let before = try #require(pipeline.process(input, at: 100))
        #expect(VirtualCameraFixtures.pixel(before, x: 300, y: 10).green > 240)
        _ = try VirtualCameraSceneLibrary.apply("Corner", in: &state)
        pipeline.update(state: state)
        let early = try #require(pipeline.process(input, at: 100.05))
        #expect(VirtualCameraFixtures.pixel(early, x: 300, y: 10).green > 200)
        let settled = try #require(pipeline.process(input, at: 101))
        let corner = VirtualCameraFixtures.pixel(settled, x: 300, y: 10)
        #expect(corner.red > 240 && corner.green < 15)
    }

    @Test func cutTransitionsJumpImmediately() throws {
        let clock = ManualClock(10)
        var state = VirtualCameraState(transition: .cut)
        _ = try VirtualCameraSceneLibrary.apply("Full frame", in: &state)
        state.scenes.append(
            VirtualCameraScene(
                name: "Corner",
                composition: VirtualCameraComposition(
                    framing: VirtualCameraFraming(zoom: 2.2, centerX: 0.25, centerY: 0.25))))
        let pipeline = VirtualCameraPipeline(
            state: state, outputSize: output, clock: { clock.now })
        let input = try #require(VirtualCameraFixtures.quadrants())
        _ = pipeline.process(input, at: 10)
        _ = try VirtualCameraSceneLibrary.apply("Corner", in: &state)
        pipeline.update(state: state)
        let frame = try #require(pipeline.process(input, at: 10.01))
        #expect(VirtualCameraFixtures.pixel(frame, x: 300, y: 10).red > 240)
    }

    @Test func privacyFramesHideTheCamera() throws {
        var state = VirtualCameraState()
        let pipeline = VirtualCameraPipeline(state: state, outputSize: output)
        let input = try #require(VirtualCameraFixtures.quadrants())
        let live = try #require(pipeline.process(input, at: 1))
        state.privacy = .freeze
        pipeline.update(state: state)
        let frozen = try #require(pipeline.privacyFrame())
        #expect(frozen === live)
        state.privacy = .blank
        pipeline.update(state: state)
        let blank = try #require(pipeline.privacyFrame())
        let dark = VirtualCameraFixtures.pixel(blank, x: 160, y: 90)
        #expect(dark.red < 5 && dark.green < 5 && dark.blue < 5)
        #expect(pipeline.privacyFrame() === blank)
        state.privacy = .card
        state.privacyMessage = "Back in five"
        pipeline.update(state: state)
        let card = try #require(pipeline.privacyFrame())
        #expect(card !== blank)
        let corner = VirtualCameraFixtures.pixel(card, x: 10, y: 10)
        #expect(corner.red < 200)
        #expect(pipeline.currentState.privacyMessage == "Back in five")
    }

    @Test func aSmallReferenceFrameIsKeptOncePerSecond() throws {
        let pipeline = VirtualCameraPipeline(state: VirtualCameraState(), outputSize: output)
        let input = try #require(VirtualCameraFixtures.quadrants())
        #expect(pipeline.reference == nil)
        _ = pipeline.process(input, at: 5)
        let first = try #require(pipeline.reference)
        #expect(first.width == Int(VirtualCameraPipeline.referenceSize.width))
        #expect(first.height == Int(VirtualCameraPipeline.referenceSize.height))
        _ = pipeline.process(input, at: 5.5)
        #expect(pipeline.reference === first)
        _ = pipeline.process(input, at: 6.1)
        #expect(pipeline.reference !== first)
    }

    @Test func lookThumbnailsCoverEveryPreset() throws {
        let renderer = VirtualCameraRenderer()
        let reference = try #require(
            renderer.cgImage(
                VirtualCameraRendererTests.quadrants(width: 224, height: 126),
                size: CGSize(width: 224, height: 126)))
        let thumbnails = VirtualCameraLooks.thumbnails(from: reference, renderer: renderer)
        #expect(Set(thumbnails.keys) == Set(VirtualCameraLookPreset.allCases))
        let size = CGSize(width: 224, height: 126)
        let reader = VirtualCameraRendererTests()
        let mono = try reader.pixels(CIImage(cgImage: try #require(thumbnails[.mono])), size: size)
        let gray = mono(20, 20)
        #expect(abs(gray.red - gray.green) < 8 && abs(gray.green - gray.blue) < 8)
        let natural = try reader.pixels(
            CIImage(cgImage: try #require(thumbnails[.natural])), size: size)
        #expect(natural(20, 20).near(.red))
        #expect(natural(20, 110).near(.blue))
    }

    @Test func stoppingClearsStatistics() throws {
        let pipeline = VirtualCameraPipeline(state: VirtualCameraState(), outputSize: output)
        let input = try #require(VirtualCameraFixtures.quadrants())
        _ = pipeline.process(input, at: 1)
        pipeline.stop()
        _ = pipeline.currentState
        #expect(pipeline.statistics == VirtualCameraPipeline.Statistics())
    }
}

@MainActor
@Suite(.serialized) struct VirtualCameraHelperTests {
    static let identifier = "com.pulkit.edith.dev.tests.camera"

    static func engine(
        hardware: FakeCameraHardware = FakeCameraHardware(),
        state: VirtualCameraState = VirtualCameraState(), obsRunning: Bool = false,
        frontmost: VirtualCameraRunningApplication? = nil
    ) -> VirtualCameraEngine {
        VirtualCameraEngine(
            edithSink: VirtualCameraSink(extensionIdentifier: identifier, hardware: hardware),
            obsSink: VirtualCameraSink(deviceUID: VirtualCameraOBS.deviceUID, hardware: hardware),
            state: state,
            environment: VirtualCameraEngineEnvironment(
                authorization: { .authorized }, obsRunning: { obsRunning },
                frontmostApplication: { frontmost }))
    }

    static func obsHardware(watching: Bool) -> FakeCameraHardware {
        let hardware = FakeCameraHardware()
        hardware.devices = [40: VirtualCameraOBS.deviceUID]
        hardware.streams = [40: [41, 42]]
        hardware.directions = [41: 1, 42: 0]
        hardware.sinkCapacity = 4
        if watching { hardware.running = [40] }
        return hardware
    }

    @Test func obsCameraStartsWhenAnAppOpensItAndStopsWhenThatAppQuits() {
        let hardware = Self.obsHardware(watching: true)
        let zoom = VirtualCameraRunningApplication(pid: 4242, bundleIdentifier: "us.zoom.xos")
        let engine = Self.engine(hardware: hardware, frontmost: zoom)
        engine.refreshExtension()
        #expect(engine.route == .obs)
        #expect(engine.streamingRoute == .obs)
        #expect(hardware.started == [42])
        #expect(engine.trigger == zoom)
        let live = engine.snapshot()
        #expect(live.headline == "Live as OBS Virtual Camera")
        #expect(live.obsAvailable)
        #expect(!live.extensionInstalled)
        engine.applicationQuit(9999)
        #expect(engine.streaming)
        engine.applicationQuit(4242)
        #expect(!engine.streaming)
        #expect(hardware.stopped == [42])
        engine.refreshExtension()
        #expect(!engine.streaming)
        engine.shutdown()
    }

    @Test func obsCameraWaitsForAnAppAndStepsAsideForOBS() {
        let idle = Self.obsHardware(watching: false)
        let waiting = Self.engine(hardware: idle)
        waiting.refreshExtension()
        #expect(waiting.route == .obs)
        #expect(!waiting.streaming)
        #expect(waiting.snapshot().headline == "Ready as OBS Virtual Camera")
        waiting.shutdown()
        let busy = Self.obsHardware(watching: true)
        let deferring = Self.engine(hardware: busy, obsRunning: true)
        deferring.refreshExtension()
        #expect(!deferring.streaming)
        #expect(busy.started.isEmpty)
        deferring.shutdown()
    }

    @Test func edithAppsDoNotCountAsTheViewer() {
        let edith = VirtualCameraRunningApplication(pid: 1, bundleIdentifier: "com.pulkit.edith")
        let dev = VirtualCameraRunningApplication(
            pid: 2, bundleIdentifier: "com.pulkit.edith.dev.main")
        let meet = VirtualCameraRunningApplication(pid: 3, bundleIdentifier: "com.google.Chrome")
        #expect(VirtualCameraEngine.trigger(from: edith) == nil)
        #expect(VirtualCameraEngine.trigger(from: dev) == nil)
        #expect(VirtualCameraEngine.trigger(from: meet) == meet)
        #expect(VirtualCameraEngine.trigger(from: nil) == nil)
    }

    @Test func choosingEdithCameraIgnoresOBS() {
        let hardware = Self.obsHardware(watching: true)
        var state = VirtualCameraState()
        state.output = .edithCamera
        let engine = Self.engine(hardware: hardware, state: state)
        engine.refreshExtension()
        #expect(engine.route == nil)
        #expect(!engine.streaming)
        #expect(engine.snapshot().headline == "Camera extension not installed")
        engine.shutdown()
    }

    static func payload(
        _ request: VirtualCameraRequest, deadline: Date = Date().addingTimeInterval(30)
    )
        -> [AnyHashable: Any]
    {
        let runtime = VirtualCameraRuntimeRequest(request: request, deadline: deadline)
        var result: [AnyHashable: Any] = [:]
        for (key, value) in runtime.payload ?? [:] { result[key] = value }
        return result
    }

    static func snapshot(in reply: [String: Any]?) -> VirtualCameraSnapshot? {
        VirtualCameraSnapshot.decode(reply?[VirtualCameraIPC.snapshotKey] as? String)
    }

    @Test func invalidRequestsAreRejected() {
        #expect(VirtualCameraActionBridge.reply(to: [:], engine: nil) == nil)
        let reply = VirtualCameraActionBridge.reply(
            to: [VirtualCameraIPC.requestIDKey: UUID().uuidString], engine: nil)
        #expect(reply?[VirtualCameraIPC.okKey] as? Bool == false)
        #expect(reply?[VirtualCameraIPC.errorKey] as? String == "The camera request is invalid.")
    }

    @Test func expiredRequestsDoNotRun() {
        let reply = VirtualCameraActionBridge.reply(
            to: Self.payload(.zoom(2), deadline: Date(timeIntervalSince1970: 1)), engine: nil)
        #expect(reply?[VirtualCameraIPC.okKey] as? Bool == false)
        #expect((reply?[VirtualCameraIPC.errorKey] as? String)?.contains("expired") == true)
    }

    @Test func aDisabledCameraStillReportsStatus() {
        let status = VirtualCameraActionBridge.reply(to: Self.payload(.status), engine: nil)
        #expect(status?[VirtualCameraIPC.okKey] as? Bool == true)
        #expect(Self.snapshot(in: status)?.helperRunning == true)
        let change = VirtualCameraActionBridge.reply(to: Self.payload(.reset), engine: nil)
        #expect(change?[VirtualCameraIPC.okKey] as? Bool == false)
        #expect(
            change?[VirtualCameraIPC.errorKey] as? String
                == VirtualCameraActionBridge.disabledMessage)
    }

    @Test func theEngineAppliesAndPersistsChanges() throws {
        let saved = SharedDefaults.store.data(forKey: AppStorageKeys.VirtualCamera.state)
        defer { SharedDefaults.store.set(saved, forKey: AppStorageKeys.VirtualCamera.state) }
        let engine = Self.engine()
        let reply = VirtualCameraActionBridge.reply(to: Self.payload(.zoom(2.5)), engine: engine)
        #expect(reply?[VirtualCameraIPC.okKey] as? Bool == true)
        let snapshot = try #require(Self.snapshot(in: reply))
        #expect(snapshot.state.composition.framing.zoom == 2.5)
        #expect(snapshot.message == "Zoom set to 2.50x.")
        #expect(snapshot.cameraAccess == "granted")
        #expect(VirtualCameraStore.load().composition.framing.zoom == 2.5)
        let failed = VirtualCameraActionBridge.reply(to: Self.payload(.zoom(20)), engine: engine)
        #expect(failed?[VirtualCameraIPC.okKey] as? Bool == false)
        #expect((failed?[VirtualCameraIPC.errorKey] as? String)?.contains("Zoom must be") == true)
        #expect(Self.snapshot(in: failed)?.state.composition.framing.zoom == 2.5)
        engine.shutdown()
    }

    @Test func theEngineReportsTheInstalledExtensionAndItsApps() {
        let hardware = FakeCameraHardware()
        let uid = VirtualCameraIdentity.deviceID(forExtension: Self.identifier).uuidString
        hardware.devices = [7: uid]
        hardware.streams = [7: [70, 71]]
        hardware.directions = [70: 1, 71: 0]
        hardware.statuses = [
            70: VirtualCameraExtensionStatus(
                build: "12", clients: ["com.apple.FaceTime"], format: .hd720,
                receivingFrames: false
            ).encoded()
        ]
        let engine = Self.engine(hardware: hardware)
        engine.refreshExtension()
        let snapshot = engine.snapshot()
        #expect(snapshot.extensionInstalled)
        #expect(snapshot.extensionBuild == "12")
        #expect(snapshot.format == .hd720)
        #expect(snapshot.clients.map(\.id) == ["com.apple.FaceTime"])
        #expect(!engine.streaming)
        engine.shutdown()
    }

    @Test func theShortcutTogglesThePause() {
        let saved = SharedDefaults.store.data(forKey: AppStorageKeys.VirtualCamera.state)
        defer { SharedDefaults.store.set(saved, forKey: AppStorageKeys.VirtualCamera.state) }
        let engine = Self.engine()
        #expect(engine.togglePause() == .card)
        #expect(engine.snapshot().state.privacy == .card)
        #expect(engine.togglePause() == .live)
        let binding = HotKeyCatalog.binding(HotKeyCatalog.virtualCamera)
        #expect(binding?.abilityID == "virtualCamera")
        #expect(binding?.defaultLabel == "⌃⌥⌘V")
        engine.shutdown()
    }

    @Test func windowRequestsRoundTripOverDistributedNotifications() async throws {
        let token = IPC.observe(IPC.Name.requestVirtualCameraAction) { info in
            let reply = MainActor.assumeIsolated {
                VirtualCameraActionBridge.reply(to: info, engine: nil)
            }
            guard let reply else { return }
            IPC.post(IPC.Name.virtualCameraActionResult, userInfo: reply)
        }
        defer { IPC.stopObserving(token) }
        let snapshot = try await VirtualCameraOperationExecution.request(
            .status, timeout: .seconds(5))
        #expect(snapshot.helperRunning)
        await #expect(throws: VirtualCameraOperationFailure.self) {
            try await VirtualCameraOperationExecution.request(.reset, timeout: .seconds(5))
        }
    }

    @Test func theEngineWithoutTheExtensionStaysIdle() {
        let engine = Self.engine()
        engine.refreshExtension()
        let snapshot = engine.snapshot()
        #expect(!snapshot.extensionInstalled)
        #expect(!snapshot.live)
        #expect(snapshot.headline == "Camera extension not installed")
        engine.shutdown()
    }
}
