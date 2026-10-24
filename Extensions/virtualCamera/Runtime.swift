import AVFoundation
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Carbon.HIToolbox
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
    private var stopError: NSError?
    private var draining = false
    private var uiStops: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let worker = self?.worker, !worker.draining else {
                throw ExtensionPeerError.unavailable
            }
            if command == "camera.snapshot",
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
            return try await worker.surface.execute(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        _ = commands.suspend()
        draining = true
        stopUI()
        let worker = worker, streams = cliStreams
        worker?.beginDrain()
        streams?.stop()
        Task { [self, worker, streams] in
            _ = await commands.suspendAndWait()
            await worker?.drain()
            await streams?.stopAndWait()
            let stops = Array(uiStops.values)
            for task in stops { await task.value }
            completion()
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        commands.shutdown()
        draining = true
        stopUI()
        cliStreams?.stop()
        let worker = worker
        worker?.beginDrain()
        if disable == nil {
            disable = Task { [self, worker] in
                await commands.shutdownAndWait()
                await cliStreams?.stopAndWait()
                try await worker?.prepareDisable()
            }
        }
        let disable = disable
        Task { [self, disable] in
            do { try await disable?.value; completion(nil) } catch {
                self.disable = nil; completion(error as NSError)
            }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        stopUI()
        commands.shutdown()
        draining = true
        stopUI()
        cliStreams?.stop()
        let worker = worker, streams = cliStreams, disable = disable
        worker?.beginDrain()
        Task { [self, worker, streams, disable] in
            await commands.shutdownAndWait()
            await worker?.drain()
            await streams?.stopAndWait()
            let stops = Array(uiStops.values)
            for task in stops { await task.value }
            do {
                if let disable {
                    try await disable.value
                } else {
                    try await worker?.prepareDisable()
                }
                stopError = nil
                completion()
            } catch {
                stopError = error as NSError
            }
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
            guard !draining, worker == nil, let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let host = input["hostIdentifier"] as? String,
                host == ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"],
                SurfaceHostContext.current != nil, let defaults = UserDefaults(suiteName: suite)
            else { return ["ok": false] as NSDictionary }
            do { worker = try CameraAppWorker(defaults: defaults, host: host) } catch {
                return ["ok": false] as NSDictionary
            }
        case "configureUI":
            guard !draining, uiStops.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                let defaults = UserDefaults(suiteName: configuration.defaultsSuite),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client;
            uiModel = VirtualCameraPageModel(engineClient: client, defaults: defaults)
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { VirtualCameraPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": worker?.installHotKey()
        case "stop":
            stopUI()
            commands.shutdown(); cliStreams?.stop()
            HotKeyRegistrar.shutdown()
            worker?.engine.shutdown()
            worker = nil
            InputFocus.uninstall()
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
        TextEditingCommands.shutdown()
        let client = uiClient; uiClient = nil
        let model = uiModel
        model?.beginSuspension()
        uiModel = nil
        if let model {
            let id = UUID()
            uiStops[id] = Task { [self, model, client] in
                defer { client?.invalidate(); uiStops[id] = nil }
                await model.shutdown()
            }
        } else {
            client?.invalidate()
        }
    }
}

struct CameraSelectedPackageLayout {
    let carrier: URL
    let privileged: URL

    init(roleURL role: URL, hostIdentifier: String) throws {
        guard role.isFileURL, role.path == role.standardizedFileURL.path,
            role.path == role.resolvingSymlinksInPath().path,
            let roleBundle = Bundle(url: role),
            roleBundle.bundleIdentifier == "com.pulkit.edith.extensions.virtualCamera.app",
            let version = roleBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String, !version.isEmpty, version.utf8.count <= 80,
            roleBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == "edith-host-2"
        else { throw ExtensionPeerError.invalidRequest }
        let suffix = [
            "ExtensionCarrier.app", "Contents", "Extensions", "ExtensionWorker.appex",
            "Contents", "Resources", "Payload", "virtualCamera", "app.bundle",
        ]
        var package = role
        for component in suffix.reversed() {
            guard package.lastPathComponent == component else {
                throw ExtensionPeerError.invalidRequest
            }
            package.deleteLastPathComponent()
        }
        let manifestURL = role.deletingLastPathComponent().appendingPathComponent("package.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard package.lastPathComponent == "virtualCamera", package.path != "/",
            manifestURL.path == manifestURL.resolvingSymlinksInPath().path,
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int, size > 0, size <= 16_384,
            let manifest = try JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)) as? [String: Any],
            manifest["id"] as? String == "virtualCamera",
            manifest["version"] as? String == version,
            manifest["hostABI"] as? String == "edith-host-2",
            manifest["architecture"] as? String == "arm64"
        else { throw ExtensionPeerError.invalidRequest }
        let carrier = package.appendingPathComponent("CameraCarrier.app")
        let privileged = role.deletingLastPathComponent().appendingPathComponent(
            "privileged.bundle")
        for url in [carrier, privileged] {
            guard url.path == url.resolvingSymlinksInPath().path else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        guard let carrierBundle = Bundle(url: carrier),
            carrierBundle.bundleIdentifier == hostIdentifier + ".cameraCarrier",
            carrierBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Edith",
            carrierBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == version,
            carrierBundle.object(forInfoDictionaryKey: "EdithContainedExtensionID") as? String
                == "virtualCamera",
            carrierBundle.object(forInfoDictionaryKey: "EdithContainedRole") as? String
                == "cameraCarrier",
            carrierBundle.object(forInfoDictionaryKey: "EdithHostIdentifier") as? String
                == hostIdentifier,
            carrierBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == "edith-host-2",
            let privilegedBundle = Bundle(url: privileged),
            privilegedBundle.bundleIdentifier
                == "com.pulkit.edith.extensions.virtualCamera.privileged",
            privilegedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == version,
            privilegedBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == "edith-host-2"
        else { throw ExtensionPeerError.invalidRequest }
        self.carrier = carrier
        self.privileged = privileged
    }
}

enum CameraCarrierLaunchEnvironment {
    static func make(
        inherited: [String: String], fixture: Bool, selectedSource: URL, carrier: URL
    ) throws -> [String: String] {
        var environment = inherited
        for key in environment.keys where key.hasPrefix("DYLD_") || key == "LD_PRELOAD" {
            environment.removeValue(forKey: key)
        }
        if fixture {
            guard selectedSource.isFileURL, carrier.isFileURL, carrier.path == selectedSource.path,
                selectedSource.path == selectedSource.standardizedFileURL.path,
                selectedSource.path == selectedSource.resolvingSymlinksInPath().path,
                selectedSource.lastPathComponent == "CameraCarrier.app",
                selectedSource.deletingLastPathComponent().path != "/",
                inherited["EDITH_EXTENSION_FIXTURE_HOME"]?.hasPrefix("/") == true
            else { throw ExtensionPeerError.invalidRequest }
            environment["EDITH_EXTENSION_FIXTURE_HOME"] =
                selectedSource.deletingLastPathComponent().path
        }
        return environment
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
    private var microphoneRemoval: Task<Void, Never>?
    private(set) var draining = false
    static let pendingKey = "cameraPendingDisable"

    init(
        defaults: UserDefaults, host: String,
        roleURL: URL = Bundle(for: ExtensionRuntime.self).bundleURL
    ) throws {
        self.defaults = defaults
        let layout = try CameraSelectedPackageLayout(roleURL: roleURL, hostIdentifier: host)
        guard let bundle = Bundle(url: roleURL) else { throw ExtensionPeerError.invalidRequest }
        source = layout.carrier
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
                    source: layout.privileged,
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
                process.environment = try CameraCarrierLaunchEnvironment.make(
                    inherited: ProcessInfo.processInfo.environment,
                    fixture: fixture, selectedSource: source, carrier: carrier)
                try process.run()
                return process
            })
        let client = self.client
        var environment = VirtualCameraEngineEnvironment.live
        if fixture {
            environment.applicationNotifications = { nil }
            environment.authorization = { .denied };
            environment.obsRunning = { hardware?.obsRunning == true }
            environment.frontmostApplication = {
                VirtualCameraRunningApplication(pid: 303303, bundleIdentifier: "synthetic.meeting")
            }; environment.sources = { [] }
        }
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
                bundleURL: bundle.bundleURL.deletingLastPathComponent(),
                hasInstallEntitlement: { false }, deviceVisible: { false }))
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
            installHotKey()
            if !fixture {
                let privilege = ExtensionPrivilegedClient(
                    owner: "virtualCamera", source: layout.privileged, version: version)
                microphoneRemoval = Task {
                    guard privilege.status == .enabled else { return }
                    _ = try? await privilege.invoke("microphoneRemove", payload: Data("{}".utf8))
                    try? await privilege.release()
                }
            }
        }
    }

    func markDraining() { draining = true }

    func installHotKey() {
        guard !fixture, !draining else { return }
        HotKeyRegistrar.configure(
            ExtensionHotKeyBinding(
                id: HotKeyCatalog.virtualCamera, carbonID: 11,
                prefix: "virtualCameraHotKey", defaultCode: kVK_ANSI_V,
                defaultModifiers: controlKey | optionKey | cmdKey))
        HotKeyRegistrar.install(HotKeyCatalog.virtualCamera) { [engine] in
            engine.togglePause()
        }
    }

    func beginDrain() {
        draining = true
        microphoneRemoval?.cancel()
        HotKeyRegistrar.shutdown()
        ui.beginSuspension()
        model.beginSuspension()
        manager.beginSuspension()
        engine.beginSuspension()
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
    }

    func drain() async {
        beginDrain()
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
