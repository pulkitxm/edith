import AVFoundation
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import CoreMedia
import CoreMediaIO
import SwiftUI

@MainActor @objc(EdithCameraExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: CameraAppWorker?
    private var uiClient: ExtensionEngineClient?
    private var uiModel: VirtualCameraPageModel?
    private let commands = ExtensionCommandRegistry()
    private let cliStreams = try? ExtensionCLIStreams(owner: "virtualCamera")
    private var disable: Task<Void, Error>?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let worker = self?.worker, !worker.draining else {
                throw ExtensionPeerError.unavailable
            }
            if command.hasPrefix("camera."),
                SurfacePrivacyState.hides(
                    .ability("virtualCamera"),
                    values: ExtensionSharedState.current?.values(for: "presenter") ?? [:])
            {
                throw ExtensionPeerError.rejected("Camera is hidden while presenting.")
            }
            if command == "virtualCamera.cli.catalog" { return try CameraCLICatalog.data() }
            if command.hasPrefix("camera.cli.stream.") {
                guard let cliStreams = self?.cliStreams else {
                    throw ExtensionPeerError.unavailable
                }
                return try CameraCLIEnvironment.$streamEngine.withValue(worker.engine) {
                    try cliStreams.invoke(
                        CameraCommand.self, operation: command, prefix: "camera.cli.stream",
                        payload: payload)
                }
            }
            if command == "camera.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await CameraCLIExecution.run(request, engine: worker.engine))
            }
            if command.hasPrefix("camera.ui.") {
                return try await worker.ui.execute(command, payload: payload)
            }
            if command == "camera.fixture" { return try worker.fixtureRequest(payload) }
            if command == "camera.snapshot" {
                guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
                return try JSONEncoder().encode(worker.engine.snapshot())
            }
            if command == "camera.request" {
                guard
                    let values = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                    let request = VirtualCameraRuntimeRequest(payload: values), request.isLive()
                else { throw ExtensionPeerError.invalidRequest }
                return try JSONEncoder().encode(
                    try await worker.engine.performRecording(request.request))
            }
            if command == "camera.extension" {
                guard
                    let values = try JSONSerialization.jsonObject(with: payload)
                        as? [String: String],
                    values.count == 1
                else { throw ExtensionPeerError.invalidRequest }
                guard values["operation"] == "microphone" else {
                    throw ExtensionPeerError.rejected(
                        "Camera video uses OBS Virtual Camera. Keep OBS Studio closed.")
                }
                try await worker.client.prepareMicrophone()
                return try JSONEncoder().encode(worker.client.currentStatus)
            }
            return try await worker.surface.execute(command, payload: payload)
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        worker?.markDraining()
        if disable == nil {
            disable = Task { [weak self] in
                guard let self, let worker else { return }
                await commands.shutdownAndWait()
                await cliStreams?.stopAndWait()
                try await worker.prepareDisable()
            }
        }
        Task { [weak self] in
            do { try await self?.disable?.value; completion(nil) } catch {
                self?.disable = nil; completion(error as NSError)
            }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        worker?.markDraining()
        Task { [weak self] in
            await self?.commands.shutdownAndWait()
            await self?.cliStreams?.stopAndWait()
            try? await self?.worker?.prepareDisable(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: Self.self)
            return [
                "id": "virtualCamera", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard worker == nil, let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let host = input["hostIdentifier"] as? String,
                host == ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"],
                SurfaceHostContext.current != nil, let defaults = UserDefaults(suiteName: suite)
            else { return ["ok": false] as NSDictionary }
            worker = CameraAppWorker(defaults: defaults, host: host)
            TextEditingCommands.install()
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let defaults = UserDefaults(suiteName: configuration.defaultsSuite),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client;
            uiModel = VirtualCameraPageModel(engineClient: client, defaults: defaults)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { VirtualCameraPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            stopUI()
            commands.shutdown(); cliStreams?.stop()
            worker?.engine.shutdown()
            worker = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
        case "status":
            return [
                "ok": true, "running": worker != nil,
                "pendingDisable": worker?.draining ?? false,
            ] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func stopUI() {
        let model = uiModel; uiModel = nil
        uiClient?.invalidate(); uiClient = nil
        if let model { Task { await model.shutdown() } }
    }
}

@MainActor final class CameraAppWorker {
    let engine: VirtualCameraEngine
    let model: VirtualCameraPageModel
    let client: CameraCarrierClient
    let surface: CameraSurface
    let ui: CameraUICommands
    private let defaults: UserDefaults
    private let source: URL
    private let installed: URL
    private let fixture: Bool
    private let fixtureHardware: CameraOBSFixtureHardware?
    private let actions = VirtualCameraActionBridge()
    private let manager: VirtualCameraExtensionManager
    private var drainTask: Task<Void, Never>?
    private(set) var draining = false
    static let pendingKey = "cameraPendingDisable"

    init(defaults: UserDefaults, host: String) {
        self.defaults = defaults
        let bundle = Bundle(for: ExtensionRuntime.self)
        let directory = bundle.bundleURL.deletingLastPathComponent()
        source = directory.appendingPathComponent("CameraCarrier.app").resolvingSymlinksInPath()
        installed = URL(
            fileURLWithPath: "/Applications/Edith Extensions/" + host + ".cameraCarrier.app")
        fixture =
            host.hasPrefix("com.pulkit.edith.tests.")
            && ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        let source = self.source, fixture = self.fixture
        fixtureHardware = fixture ? CameraOBSFixtureHardware() : nil
        let hardware = fixtureHardware
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        client = CameraCarrierClient(
            prepare: {
                if fixture { return source }
                let privilege = ExtensionPrivilegedClient(
                    owner: "virtualCamera",
                    source: directory.appendingPathComponent("privileged.bundle"),
                    version: version)
                if privilege.status != .enabled { try privilege.requestApproval() }
                let payload = try JSONSerialization.data(withJSONObject: ["source": source.path])
                let result = try await privilege.invoke("installCarrier", payload: payload)
                guard
                    let values = try JSONSerialization.jsonObject(with: result)
                        as? [String: String],
                    values.count == 1, let path = values["path"],
                    path == "/Applications/Edith Extensions/" + host + ".cameraCarrier.app"
                else { throw ExtensionPeerError.invalidRequest }
                try await privilege.release()
                return URL(fileURLWithPath: path)
            },
            launch: { carrier in
                guard let executable = Bundle(url: carrier)?.executableURL else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let process = Process()
                process.executableURL = executable
                process.arguments = [
                    fixture ? "--contained-extension-fixture-session" : "--contained-extension-role"
                ]
                process.standardInput = Pipe(); process.standardOutput = Pipe()
                process.standardError = fixture ? FileHandle.standardError : FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                for key in environment.keys where key.hasPrefix("DYLD_") || key == "LD_PRELOAD" {
                    environment.removeValue(forKey: key)
                }
                process.environment = environment
                try process.run()
                return process
            })
        let client = self.client
        var environment = VirtualCameraEngineEnvironment.live
        if fixture {
            environment.authorization = { .denied };
            environment.obsRunning = { hardware?.obsRunning == true }
            environment.frontmostApplication = {
                VirtualCameraRunningApplication(pid: 303303, bundleIdentifier: "synthetic.meeting")
            }; environment.sources = { [] }
        }
        environment.prepareMicrophone = { try await client.prepareMicrophone() }
        let bus = VirtualCameraPreviewBus()
        var state = VirtualCameraStore.load(defaults)
        state.output = .obs
        VirtualCameraStore.save(state, to: defaults)
        if let hardware {
            engine = VirtualCameraEngine(
                edithSink: VirtualCameraSink(
                    deviceUID: "synthetic-no-custom-provider", hardware: hardware),
                obsSink: VirtualCameraSink(
                    deviceUID: VirtualCameraOBS.deviceUID, hardware: hardware),
                state: state, environment: environment, previewBus: bus)
        } else {
            engine = VirtualCameraEngine(state: state, environment: environment, previewBus: bus)
        }
        surface = CameraSurface(engine: engine)
        manager = VirtualCameraExtensionManager(
            environment: .init(
                bundleURL: directory, hasInstallEntitlement: { false }, deviceVisible: { false }))
        model = VirtualCameraPageModel(
            defaults: defaults, extensionManager: manager,
            accessProvider: environment.authorization, sourceProvider: environment.sources,
            previewBus: bus,
            requestHandler: { [engine = self.engine] in try await engine.performRecording($0) })
        ui = CameraUICommands(engine: engine, model: model, defaults: defaults)
        draining =
            defaults.bool(forKey: Self.pendingKey)
            || ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"] == "1"
        if !draining {
            engine.start(); actions.install(engine: engine)

        }
    }

    func markDraining() { draining = true }

    func drain() async {
        draining = true
        if drainTask == nil {
            drainTask = Task { [self] in
                CameraExtensionBridge.shutdown()
                await actions.shutdown()
                await ui.shutdown()
                await model.shutdown()
                await manager.shutdown()
                await engine.finishShutdown()
                await ScreenCaptureSourceCatalog.shutdownAll()
                CameraPrivacy.shared.shutdown()
            }
        }
        await drainTask?.value
    }

    func prepareDisable() async throws {
        defaults.set(true, forKey: Self.pendingKey)
        await drain()
        let installedCarrier = !fixture && FileManager.default.fileExists(atPath: installed.path)
        try await client.prepareDisable(providerVisible: installedCarrier)
        defaults.removeObject(forKey: Self.pendingKey)
    }

    func fixtureRequest(_ payload: Data) throws -> Data {
        guard fixture, let hardware = fixtureHardware, payload.count <= 1024,
            let values = try JSONSerialization.jsonObject(with: payload) as? [String: Bool],
            Set(values.keys).isSubset(of: ["watching", "obsRunning", "applicationQuit"])
        else { throw ExtensionPeerError.invalidRequest }
        if let watching = values["watching"] { hardware.watching = watching }
        if let running = values["obsRunning"] { hardware.obsRunning = running }
        engine.refreshExtension()
        if values["applicationQuit"] == true { engine.applicationQuit(303303) }
        return try JSONEncoder().encode(engine.snapshot())
    }

}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}

private final class CameraOBSFixtureHardware: VirtualCameraHardware, @unchecked Sendable {
    var watching = false
    var obsRunning = false
    private var queues: [CMIOStreamID: CMSimpleQueue] = [:]
    func deviceIDs() -> [CMIOObjectID] { [40] }
    func string(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        object == 40 && selector == CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            ? VirtualCameraOBS.deviceUID : nil
    }
    func streamIDs(_ device: CMIOObjectID) -> [CMIOStreamID] { device == 40 ? [41, 42] : [] }
    func direction(_ stream: CMIOStreamID) -> UInt32? {
        stream == 41 ? 1 : (stream == 42 ? 0 : nil)
    }
    func flag(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> Bool? {
        object == 40
            && selector == CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
            ? watching : nil
    }
    func startSink(device: CMIOObjectID, stream: CMIOStreamID) -> CMSimpleQueue? {
        var queue: CMSimpleQueue?
        CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: 4, queueOut: &queue)
        queues[stream] = queue
        return queue
    }
    func stopSink(device: CMIOObjectID, stream: CMIOStreamID) {
        guard let queue = queues.removeValue(forKey: stream) else { return }
        while let sample = CMSimpleQueueDequeue(queue) {
            Unmanaged<CMSampleBuffer>.fromOpaque(sample).release()
        }
    }
    func listen(
        _ object: CMIOObjectID, selector: CMIOObjectPropertySelector, queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> VirtualCameraListener? { VirtualCameraListener(remove: {}) }
}
