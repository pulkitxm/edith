import AVFoundation
import CoreMediaIO
import EdithCameraSupport
import EdithCore
import Foundation
import Testing

@testable import EdithKit

@Suite struct VirtualCameraRequestReducerTests {
    let sources = [
        VirtualCameraSource(id: "a", name: "FaceTime HD Camera", kind: .builtIn),
        VirtualCameraSource(id: "b", name: "Studio Display Camera", kind: .external),
        VirtualCameraSource(id: "c", name: "Pat's iPhone Camera", kind: .continuity),
    ]

    func apply(_ request: VirtualCameraRequest, to state: inout VirtualCameraState) throws -> String
    {
        try VirtualCameraRequestReducer.apply(
            request, to: &state, sources: sources, fileExists: { $0.hasPrefix("/exists") })
    }

    @Test func statusChangesNothing() throws {
        var state = VirtualCameraState()
        let before = state
        _ = try apply(.status, to: &state)
        #expect(state == before)
        #expect(!VirtualCameraRequest.status.changesState)
        #expect(VirtualCameraRequest.reset.changesState)
    }

    @Test func sourcesResolveByIdNameNumberAndUniquePart() throws {
        #expect(try VirtualCameraRequestReducer.resolveSource("b", in: sources).id == "b")
        #expect(
            try VirtualCameraRequestReducer.resolveSource("facetime hd camera", in: sources).id
                == "a")
        #expect(try VirtualCameraRequestReducer.resolveSource("3", in: sources).id == "c")
        #expect(try VirtualCameraRequestReducer.resolveSource("iphone", in: sources).id == "c")
        #expect(throws: VirtualCameraRequestError.self) {
            try VirtualCameraRequestReducer.resolveSource("Camera", in: sources)
        }
        #expect(throws: VirtualCameraRequestError.noCameras) {
            try VirtualCameraRequestReducer.resolveSource("a", in: [])
        }
        var state = VirtualCameraState()
        #expect(try apply(.selectSource("studio"), to: &state) == "Using Studio Display Camera.")
        #expect(state.sourceID == "b")
    }

    @Test func zoomAndFrameAreValidated() throws {
        var state = VirtualCameraState()
        _ = try apply(.zoom(2), to: &state)
        #expect(state.composition.framing.zoom == 2)
        #expect(throws: VirtualCameraRequestError.zoomOutOfRange(9)) {
            try apply(.zoom(9), to: &state)
        }
        #expect(throws: VirtualCameraRequestError.self) { try apply(.zoom(.nan), to: &state) }
        _ = try apply(
            .frame(
                VirtualCameraFrameChange(
                    zoom: 3, centerX: 0.2, centerY: 0.8, tilt: -5, quarterTurns: 2,
                    flipHorizontal: true, flipVertical: false, autoFrame: .wide)), to: &state)
        let framing = state.composition.framing
        #expect(framing.zoom == 3 && framing.centerX == 0.2 && framing.centerY == 0.8)
        #expect(framing.tilt == -5 && framing.quarterTurns == 2 && framing.flipHorizontal)
        #expect(framing.autoFrame == .wide)
        #expect(throws: VirtualCameraRequestError.emptyFrameChange) {
            try apply(.frame(VirtualCameraFrameChange()), to: &state)
        }
        #expect(throws: VirtualCameraRequestError.valueOutOfRange("x", 0...1)) {
            try apply(.frame(VirtualCameraFrameChange(centerX: 1.5)), to: &state)
        }
        #expect(throws: VirtualCameraRequestError.self) {
            try apply(.frame(VirtualCameraFrameChange(quarterTurns: 4)), to: &state)
        }
        #expect(throws: VirtualCameraRequestError.self) {
            try apply(.frame(VirtualCameraFrameChange(tilt: 60)), to: &state)
        }
        _ = try apply(.reset, to: &state)
        #expect(state.composition.framing == VirtualCameraFraming())
    }

    @Test func looksResetTheirStrength() throws {
        var state = VirtualCameraState()
        state.composition.look.intensity = 0.3
        #expect(try apply(.look(.noir), to: &state) == "Look set to Noir.")
        #expect(state.composition.look.preset == .noir)
        #expect(state.composition.look.intensity == 1)
    }

    @Test func backgroundsNeedReadableImages() throws {
        var state = VirtualCameraState()
        _ = try apply(
            .background(
                VirtualCameraBackgroundChange(
                    mode: .blur, blur: 0.9)), to: &state)
        #expect(state.composition.background.mode == .blur)
        #expect(state.composition.background.blur == 0.9)
        #expect(throws: VirtualCameraRequestError.self) {
            try apply(.background(VirtualCameraBackgroundChange(mode: .blur, blur: 3)), to: &state)
        }
        #expect(throws: VirtualCameraRequestError.missingFile("/missing/b.png")) {
            try apply(
                .background(
                    VirtualCameraBackgroundChange(mode: .image, imagePath: "/missing/b.png")),
                to: &state)
        }
        #expect(throws: VirtualCameraRequestError.unsupportedImage("notes.txt")) {
            try apply(
                .background(
                    VirtualCameraBackgroundChange(mode: .image, imagePath: "/exists/notes.txt")),
                to: &state)
        }
        #expect(throws: VirtualCameraRequestError.self) {
            try apply(.background(VirtualCameraBackgroundChange(mode: .image)), to: &state)
        }
        _ = try apply(
            .background(VirtualCameraBackgroundChange(mode: .image, imagePath: "/exists/b.png")),
            to: &state)
        #expect(state.composition.background.imagePath == "/exists/b.png")
        #expect(state.composition.background.mode == .image)
        #expect(state.composition.background.mode == .image)
    }

    @Test func pausingNeedsARealPause() throws {
        var state = VirtualCameraState()
        #expect(throws: VirtualCameraRequestError.notAPause) {
            try apply(.pause(.live, message: nil), to: &state)
        }
        _ = try apply(.pause(.card, message: "  "), to: &state)
        #expect(state.privacy == .card)
        #expect(state.privacyMessage == VirtualCameraState.defaultPrivacyMessage)
        _ = try apply(.pause(.freeze, message: "Back in 5"), to: &state)
        #expect(state.privacyMessage == "Back in 5")
        _ = try apply(.resume, to: &state)
        #expect(state.privacy == .live)
    }

    @Test func sceneErrorsAreWrapped() throws {
        var state = VirtualCameraState()
        #expect(throws: VirtualCameraRequestError.scene(.notFound("Missing"))) {
            try apply(.applyScene("Missing"), to: &state)
        }
        #expect(try apply(.saveScene("Talk", replace: false), to: &state) == "Scene Talk saved.")
        #expect(throws: VirtualCameraRequestError.scene(.duplicateName("talk"))) {
            try apply(.saveScene("talk", replace: false), to: &state)
        }
        #expect(try apply(.stepScene(1), to: &state).hasPrefix("Scene "))
        var empty = VirtualCameraState(scenes: [])
        #expect(throws: VirtualCameraRequestError.self) { try apply(.stepScene(1), to: &empty) }
    }

    @Test func errorMessagesReadWell() {
        #expect(
            VirtualCameraRequestError.zoomOutOfRange(0.5).errorDescription
                == "Zoom must be between 1 and 8, not 0.50.")
        #expect(
            VirtualCameraRequestError.valueOutOfRange("tilt", -45...45).errorDescription
                == "tilt must be between -45 and 45.")
        #expect(
            VirtualCameraRequestError.unknownSource("x", ["A", "B"]).errorDescription
                == "No camera matches x. Cameras: A, B.")
    }
}

@Suite struct VirtualCameraWireTests {
    @Test func requestsRoundTripAsJSON() throws {
        let requests: [VirtualCameraRequest] = [
            .status, .selectSource("a"), .zoom(1.5), .frame(VirtualCameraFrameChange(centerX: 0.3)),
            .reset, .look(.film),
            .background(VirtualCameraBackgroundChange(mode: .color, color: .accent)),
            .pause(.card, message: "Hi"), .resume, .applyScene("Close-up"),
            .saveScene("Talk", replace: true), .stepScene(-1),
        ]
        for request in requests {
            let text = try #require(request.encoded)
            #expect(VirtualCameraRequest.decode(text) == request)
        }
        #expect(VirtualCameraRequest.decode("{\"launch\":{}}") == nil)
    }

    @Test func runtimeRequestsRejectBadPayloads() throws {
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        let runtime = VirtualCameraRuntimeRequest(request: .zoom(2), deadline: deadline)
        let payload = try #require(runtime.payload)
        #expect(VirtualCameraRuntimeRequest(payload: payload) == runtime)
        #expect(runtime.isLive(at: Date(timeIntervalSince1970: 1_000)))
        #expect(!runtime.isLive(at: deadline))
        var badID = payload
        badID[VirtualCameraIPC.requestIDKey] = "not-a-uuid"
        #expect(VirtualCameraRuntimeRequest(payload: badID) == nil)
        var badRequest = payload
        badRequest[VirtualCameraIPC.requestKey] = "{}"
        #expect(VirtualCameraRuntimeRequest(payload: badRequest) == nil)
        var badDeadline = payload
        badDeadline[VirtualCameraIPC.deadlineKey] = Double.infinity
        #expect(VirtualCameraRuntimeRequest(payload: badDeadline) == nil)
    }

    @Test func snapshotsRoundTripAndDescribeThemselves() throws {
        var state = VirtualCameraState()
        var snapshot = VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: true,
            clients: [VirtualCameraClient(id: "us.zoom.xos", name: "zoom.us")], live: true,
            state: state)
        let decoded = try #require(VirtualCameraSnapshot.decode(snapshot.encoded))
        #expect(decoded == snapshot)
        #expect(snapshot.headline == "Live in zoom.us")
        state.privacy = .blank
        snapshot.state = state
        #expect(snapshot.headline == "Paused: Blank")
        snapshot.clients = []
        snapshot.live = false
        #expect(snapshot.headline == "Ready, no app is using it")
        snapshot.extensionInstalled = false
        #expect(snapshot.headline == "Camera extension not installed")
        snapshot.helperRunning = false
        #expect(snapshot.headline == "Waiting for Edith")
        snapshot.enabled = false
        #expect(snapshot.headline == "Off")
        #expect(VirtualCameraSnapshot.decode("{") == nil)
        #expect(VirtualCameraSnapshot.decode(nil) == nil)
    }

    @Test func resultPayloadsCarryOutcome() {
        let snapshot = VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: false,
            state: VirtualCameraState())
        let ok = snapshot.resultPayload(requestID: "id")
        #expect(ok[VirtualCameraIPC.okKey] as? Bool == true)
        #expect(ok[VirtualCameraIPC.requestIDKey] as? String == "id")
        #expect(ok[VirtualCameraIPC.snapshotKey] is String)
        let failed = snapshot.resultPayload(requestID: nil, error: "nope")
        #expect(failed[VirtualCameraIPC.okKey] as? Bool == false)
        #expect(failed[VirtualCameraIPC.errorKey] as? String == "nope")
        #expect(failed[VirtualCameraIPC.requestIDKey] == nil)
    }

    @Test func jsonCarriesTheDocumentedFields() {
        var snapshot = VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: true, extensionBuild: "7",
            source: VirtualCameraSource(id: "a", name: "Cam", kind: .builtIn), sourceWidth: 1920,
            sourceHeight: 1080, state: VirtualCameraState())
        snapshot.message = "Done."
        guard case .object(let object) = snapshot.jsonValue else {
            Issue.record("status JSON is not an object")
            return
        }
        #expect(
            Set(object.keys) == [
                "enabled", "helperRunning", "extensionInstalled", "extensionBuild", "live",
                "headline", "apps", "framesPerSecond", "camera", "cameraResolution", "output",
                "cameraAccess", "privacy", "privacyMessage", "scene", "sceneModified", "framing",
                "look", "background", "message",
            ])
        #expect(object["cameraResolution"] == .string("1920x1080"))
        #expect(object["message"] == .string("Done."))
        guard case .array(let scenes) = snapshot.scenesJSON else {
            Issue.record("scenes JSON is not an array")
            return
        }
        #expect(scenes.count == 2)
        #expect(snapshot.summaryLines.contains("camera: Cam (1920x1080)"))
    }

    @Test func operationsDescribeTheCameraGroup() {
        let descriptors = VirtualCameraOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.cli.first == "camera" && !$0.summary.isEmpty })
        #expect(VirtualCameraOperation.sceneApply.descriptor.cli == ["camera", "scene", "apply"])
        #expect(VirtualCameraOperation.status.descriptor.effect == .read)
        #expect(VirtualCameraOperation.zoom.descriptor.effect == .write)
        let registered = Set(UserOperationCatalog.descriptors.map(\.id))
        #expect(descriptors.allSatisfy { registered.contains($0.id) })
    }

    @Test func clientNamesFallBackThroughBundleParents() {
        let known = ["com.google.Chrome": "Google Chrome", "us.zoom.xos": "zoom.us"]
        let resolver: VirtualCameraClients.Resolver = { known[$0] }
        #expect(VirtualCameraClients.name(for: "us.zoom.xos", resolver: resolver) == "zoom.us")
        #expect(
            VirtualCameraClients.name(for: "com.google.Chrome.helper", resolver: resolver)
                == "Google Chrome")
        #expect(
            VirtualCameraClients.name(for: "com.unknown.tool", resolver: resolver)
                == "com.unknown.tool")
        #expect(VirtualCameraClients.name(for: "unknown", resolver: resolver) == "unknown")
        let clients = VirtualCameraClients.clients(
            ["com.google.Chrome.helper", "com.google.Chrome", "us.zoom.xos"], resolver: resolver)
        #expect(clients.map(\.name) == ["Google Chrome", "zoom.us"])
        #expect(VirtualCameraClients.accessDescription(.authorized) == "granted")
        #expect(VirtualCameraClients.accessDescription(.notDetermined) == "notRequested")
    }
}

@Suite struct VirtualCameraDemandTests {
    @Test func streamingFollowsApps() {
        #expect(
            VirtualCameraDemand.next(
                installed: true, inUse: true, streaming: false, stopPending: false)
                == .start)
        #expect(
            VirtualCameraDemand.next(
                installed: true, inUse: true, streaming: true, stopPending: true)
                == .keepStreaming)
        #expect(
            VirtualCameraDemand.next(
                installed: true, inUse: false, streaming: true, stopPending: false)
                == .scheduleStop)
        #expect(
            VirtualCameraDemand.next(
                installed: true, inUse: false, streaming: true, stopPending: true)
                == .waitForStop)
        #expect(
            VirtualCameraDemand.next(
                installed: false, inUse: true, streaming: false, stopPending: false)
                == .idle)
        #expect(
            VirtualCameraDemand.next(
                installed: false, inUse: true, streaming: true, stopPending: false)
                == .scheduleStop)
    }
}

final class FakeCameraHardware: VirtualCameraHardware, @unchecked Sendable {
    var devices: [CMIOObjectID: String] = [:]
    var streams: [CMIOObjectID: [CMIOStreamID]] = [:]
    var directions: [CMIOStreamID: UInt32] = [:]
    var statuses: [CMIOObjectID: String] = [:]
    var sinkCapacity: Int32?
    private(set) var started: [CMIOStreamID] = []
    private(set) var stopped: [CMIOStreamID] = []
    private(set) var handlers: [CMIOObjectID: @Sendable () -> Void] = [:]
    private(set) var removedListeners = 0
    private(set) var queue: CMSimpleQueue?

    func deviceIDs() -> [CMIOObjectID] { devices.keys.sorted() }

    func string(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        if selector == CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID) {
            return devices[object]
        }
        if selector == CMIOObjectPropertySelector(VirtualCameraProperty.statusCode) {
            return statuses[object]
        }
        return nil
    }

    func streamIDs(_ device: CMIOObjectID) -> [CMIOStreamID] { streams[device] ?? [] }

    func direction(_ stream: CMIOStreamID) -> UInt32? { directions[stream] }

    func startSink(device: CMIOObjectID, stream: CMIOStreamID) -> CMSimpleQueue? {
        guard let sinkCapacity else { return nil }
        var created: CMSimpleQueue?
        CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault, capacity: sinkCapacity, queueOut: &created)
        started.append(stream)
        queue = created
        return created
    }

    func stopSink(device: CMIOObjectID, stream: CMIOStreamID) {
        stopped.append(stream)
    }

    func listen(
        _ object: CMIOObjectID, selector: CMIOObjectPropertySelector, queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> VirtualCameraListener? {
        handlers[object] = handler
        return VirtualCameraListener { [weak self] in self?.removedListeners += 1 }
    }

    func drain() -> [CMSampleBuffer] {
        guard let queue else { return [] }
        var samples: [CMSampleBuffer] = []
        while let element = CMSimpleQueueDequeue(queue) {
            samples.append(Unmanaged<CMSampleBuffer>.fromOpaque(element).takeRetainedValue())
        }
        return samples
    }
}

@Suite struct VirtualCameraLocatorTests {
    let identifier = "com.pulkit.edith.camera"
    var uid: String { VirtualCameraIdentity.deviceID(forExtension: identifier).uuidString }

    @Test func findsTheDeviceAndItsStreamsByDirection() throws {
        let hardware = FakeCameraHardware()
        hardware.devices = [10: "other-camera", 20: uid]
        hardware.streams = [20: [201, 202]]
        hardware.directions = [
            201: VirtualCameraLocator.sinkDirection, 202: VirtualCameraLocator.sourceDirection,
        ]
        let found = try #require(VirtualCameraLocator.find(uid: uid, hardware: hardware))
        #expect(found == VirtualCameraEndpoints(device: 20, source: 202, sink: 201))
        #expect(VirtualCameraLocator.find(uid: "missing", hardware: hardware) == nil)
    }

    @Test func fallsBackToStreamOrderWithoutDirections() throws {
        let hardware = FakeCameraHardware()
        hardware.devices = [20: uid]
        hardware.streams = [20: [301, 302]]
        let found = try #require(VirtualCameraLocator.find(uid: uid, hardware: hardware))
        #expect(found.source == 301)
        #expect(found.sink == 302)
        hardware.streams = [20: [401]]
        let single = try #require(VirtualCameraLocator.find(uid: uid, hardware: hardware))
        #expect(single.sink == nil)
    }

    @Test func statusPrefersTheSourceStreamAndIgnoresGarbage() throws {
        let hardware = FakeCameraHardware()
        let endpoints = VirtualCameraEndpoints(device: 20, source: 202, sink: 201)
        let deviceStatus = VirtualCameraExtensionStatus(
            build: "1", clients: [], format: .hd720, receivingFrames: false)
        let streamStatus = VirtualCameraExtensionStatus(
            build: "1", clients: ["us.zoom.xos"], format: .hd1080, receivingFrames: true)
        hardware.statuses = [20: deviceStatus.encoded(), 202: streamStatus.encoded()]
        #expect(VirtualCameraLocator.status(at: endpoints, hardware: hardware) == streamStatus)
        hardware.statuses = [20: deviceStatus.encoded(), 202: "garbage"]
        #expect(VirtualCameraLocator.status(at: endpoints, hardware: hardware) == deviceStatus)
        hardware.statuses = [:]
        #expect(VirtualCameraLocator.status(at: endpoints, hardware: hardware) == nil)
    }

    @Test func sinkConnectsSendsAndDisconnects() throws {
        let hardware = FakeCameraHardware()
        hardware.devices = [20: uid]
        hardware.streams = [20: [201, 202]]
        hardware.directions = [201: 0, 202: 1]
        let sink = VirtualCameraSink(extensionIdentifier: identifier, hardware: hardware)
        #expect(!sink.connect())
        hardware.sinkCapacity = 2
        #expect(sink.connect())
        #expect(sink.connect())
        #expect(hardware.started == [201])
        let buffer = try #require(VirtualCameraPlaceholder.makeBuffer(width: 64, height: 36))
        #expect(sink.send(buffer, frameRate: 30))
        #expect(sink.send(buffer, frameRate: 30))
        #expect(!sink.send(buffer, frameRate: 30))
        let samples = hardware.drain()
        #expect(samples.count == 2)
        #expect(samples.first?.duration == CMTime(value: 1, timescale: 30))
        #expect(samples.first?.imageBuffer.map { CVPixelBufferGetWidth($0) } == 64)
        #expect(sink.send(buffer, frameRate: 30))
        sink.disconnect()
        #expect(hardware.stopped == [201])
        #expect(!sink.isConnected)
        #expect(!sink.send(buffer, frameRate: 30))
    }

    @Test func sinkWatchesTheDeviceListAndStatus() {
        let hardware = FakeCameraHardware()
        let sink = VirtualCameraSink(extensionIdentifier: identifier, hardware: hardware)
        sink.observe {}
        #expect(sink.listenerCount == 1)
        #expect(hardware.handlers.keys.contains(CMIOObjectID(kCMIOObjectSystemObject)))
        hardware.devices = [20: uid]
        hardware.streams = [20: [201, 202]]
        hardware.directions = [201: 0, 202: 1]
        sink.observe {}
        #expect(sink.listenerCount == 3)
        #expect(hardware.removedListeners == 1)
        #expect(Set(hardware.handlers.keys).isSuperset(of: [20, 202]))
        sink.stopObserving()
        #expect(sink.listenerCount == 0)
        #expect(hardware.removedListeners == 4)
    }

    @Test func sinkReportsInstallAndStatusThroughItsHardware() {
        let hardware = FakeCameraHardware()
        let sink = VirtualCameraSink(extensionIdentifier: identifier, hardware: hardware)
        #expect(!sink.isInstalled)
        #expect(sink.status() == nil)
        #expect(!sink.connect())
        hardware.devices = [20: uid]
        hardware.streams = [20: [201, 202]]
        hardware.directions = [201: 0, 202: 1]
        let status = VirtualCameraExtensionStatus(
            build: "3", clients: ["com.apple.FaceTime"], format: .hd1080, receivingFrames: false)
        hardware.statuses = [202: status.encoded()]
        #expect(sink.isInstalled)
        #expect(sink.status() == status)
        #expect(!sink.isConnected)
        #expect(sink.deviceUID == uid)
    }
}

@Suite struct VirtualCameraFormatChooserTests {
    let options = [
        VirtualCameraFormatOption(index: 0, width: 640, height: 480, maxFrameRate: 30),
        VirtualCameraFormatOption(index: 1, width: 1280, height: 720, maxFrameRate: 60),
        VirtualCameraFormatOption(index: 2, width: 1920, height: 1080, maxFrameRate: 30),
        VirtualCameraFormatOption(index: 3, width: 3840, height: 2160, maxFrameRate: 15),
        VirtualCameraFormatOption(index: 4, width: 1920, height: 1080, maxFrameRate: 60),
    ]

    @Test func picksTheSmallestFormatThatIsWideAndFastEnough() {
        #expect(
            VirtualCameraFormatChooser.choose(options, minimumWidth: 1280, frameRate: 30)?.index
                == 1)
        #expect(
            VirtualCameraFormatChooser.choose(options, minimumWidth: 1920, frameRate: 30)?.index
                == 4)
        #expect(
            VirtualCameraFormatChooser.choose(options, minimumWidth: 3840, frameRate: 30)?.index
                == 4)
        #expect(
            VirtualCameraFormatChooser.choose(options, minimumWidth: 3840, frameRate: 15)?.index
                == 3)
        #expect(VirtualCameraFormatChooser.choose([], minimumWidth: 1920, frameRate: 30) == nil)
        let slow = [
            VirtualCameraFormatOption(index: 0, width: 1920, height: 1080, maxFrameRate: 15)
        ]
        #expect(
            VirtualCameraFormatChooser.choose(slow, minimumWidth: 1280, frameRate: 30)?.index == 0)
    }

    @Test func sharpZoomRequestsStandardWidthSteps() {
        var state = VirtualCameraState()
        let output = CGSize(width: 1920, height: 1080)
        #expect(VirtualCameraPipeline.minimumSourceWidth(for: state, output: output) == 1920)
        state.composition.framing.zoom = 1.2
        #expect(VirtualCameraPipeline.minimumSourceWidth(for: state, output: output) == 2560)
        state.composition.framing.zoom = 3
        #expect(VirtualCameraPipeline.minimumSourceWidth(for: state, output: output) == 3840)
        state.sharpZoom = false
        #expect(VirtualCameraPipeline.minimumSourceWidth(for: state, output: output) == 1920)
        state.sharpZoom = true
        state.composition.framing.zoom = 1
        state.composition.framing.autoFrame = .medium
        #expect(VirtualCameraPipeline.minimumSourceWidth(for: state, output: output) == 3840)
        #expect(
            VirtualCameraPipeline.minimumSourceWidth(
                for: VirtualCameraState(), output: CGSize(width: 1280, height: 720)) == 1280)
    }
}

@Suite(.serialized) struct VirtualCameraStoreTests {
    func defaults() -> (UserDefaults, String) {
        let name = "test.edith.virtual-camera.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func stateRoundTripsThroughDefaults() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(VirtualCameraStore.load(defaults) == VirtualCameraState())
        var state = VirtualCameraState()
        state.composition.framing.zoom = 2
        state.privacy = .freeze
        VirtualCameraStore.save(state, to: defaults)
        #expect(VirtualCameraStore.load(defaults) == state)
        defaults.set(Data("not json".utf8), forKey: AppStorageKeys.VirtualCamera.state)
        #expect(VirtualCameraStore.load(defaults) == VirtualCameraState())
        defaults.set(true, forKey: AppStorageKeys.VirtualCamera.enabled)
        #expect(VirtualCameraStore.isEnabled(defaults))
    }

    @Test func changeNotificationsCarryTheWholeState() {
        var state = VirtualCameraState()
        state.composition.look.preset = .vivid
        var info: [AnyHashable: Any] = [:]
        if let data = VirtualCameraStore.encode(state) {
            info[VirtualCameraIPC.stateKey] = String(decoding: data, as: UTF8.self)
        }
        #expect(VirtualCameraStore.announcedState(info) == state.sanitized())
        #expect(VirtualCameraStore.announcedState([:]) == nil)
        #expect(VirtualCameraStore.announcedState([VirtualCameraIPC.stateKey: "{"]) == nil)
    }

    @Test func assetsAreCopiedAndPruned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-camera-store-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("logo.PNG")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let text = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        #expect(throws: VirtualCameraRequestError.unsupportedImage("notes.txt")) {
            try VirtualCameraStore.importAsset(from: text, directory: assets)
        }
        #expect(throws: VirtualCameraRequestError.self) {
            try VirtualCameraStore.importAsset(
                from: root.appendingPathComponent("gone.png"), directory: assets)
        }
        let first = try VirtualCameraStore.importAsset(from: image, directory: assets)
        let second = try VirtualCameraStore.importAsset(from: image, directory: assets)
        #expect(first.pathExtension == "png")
        #expect(first != second)
        var state = VirtualCameraState()
        state.composition.overlays.logo = VirtualCameraLogo(enabled: true, imagePath: first.path)
        #expect(VirtualCameraStore.referencedAssets(in: state) == [first.path])
        let removed = VirtualCameraStore.pruneAssets(keeping: state, directory: assets)
        #expect(removed.map(\.lastPathComponent) == [second.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: first.path))
        state.scenes[0].composition.background = VirtualCameraBackground(
            mode: .image, imagePath: "/elsewhere.png")
        #expect(VirtualCameraStore.referencedAssets(in: state) == [first.path, "/elsewhere.png"])
    }
}

@Suite struct VirtualCameraReadinessTests {
    @Test func readinessExplainsWhatIsMissing() {
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .notDetermined, cameraCount: { 1 }, extensionInstalled: { true })
                == .needsSetup("Camera access has not been requested."))
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .denied, cameraCount: { 1 }, extensionInstalled: { true })
                == .needsSetup("Camera access is denied in System Settings."))
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .restricted, cameraCount: { 1 }, extensionInstalled: { true })
                == .unsupported("macOS does not allow Edith to use the camera."))
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .authorized, cameraCount: { 0 }, extensionInstalled: { true })
                == .needsSetup("No camera is connected."))
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .authorized, cameraCount: { 2 }, extensionInstalled: { false })
                == .needsSetup("Install the Edith Camera extension from the Virtual Camera page."))
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .authorized, cameraCount: { 2 }, extensionInstalled: { true })
                == .ready("Edith Camera is installed with 2 cameras to frame."))
        #expect(
            ExtensionLiveAdapters.virtualCameraReadiness(
                status: .authorized, cameraCount: { 1 }, extensionInstalled: { true })
                == .ready("Edith Camera is installed with 1 camera to frame."))
    }

    @Test func enablingTheExtensionAsksForTheCamera() throws {
        let entry = try #require(ExtensionRegistry.entry("virtualCamera"))
        #expect(entry.requiredPermissions == [.camera])
        #expect(entry.host == .bar)
        #expect(entry.suite == .media)
        #expect(entry.defaultsKey == AppStorageKeys.VirtualCamera.enabled)
        let groups = OnboardingFlow.permissionsBySuite(selectedIDs: ["virtualCamera"], granted: [:])
        let media = groups.first { $0.suite.id == .media }?.permissions ?? []
        #expect(media.first { $0.permission == .camera }?.required == true)
        #expect(SettingsBackup.backedKeys.contains(AppStorageKeys.VirtualCamera.state))
        #expect(ExtensionLifecycleCatalog.descriptor(for: "virtualCamera") != nil)
    }
}
