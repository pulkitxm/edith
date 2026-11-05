import AVFoundation
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Carbon.HIToolbox
import Foundation
import Security
import ServiceManagement
import SwiftUI

@MainActor
final class CameraService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: CameraAppWorker?
    private var uiClient: ExtensionEngineClient?
    private var uiModel: VirtualCameraPageModel?
    private let cliStreams = try? ExtensionCLIStreams(owner: "virtualCamera")
    private var disable: Task<Void, Error>?
    private var draining = false
    private var uiStops: [UUID: Task<Void, Never>] = [:]

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var preparesForDisable: Bool { true }
    var isRunning: Bool { worker != nil }
    var statusDetails: [String: Any] { ["pendingDisable": worker?.draining ?? false] }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker = worker, !worker.draining else {
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
            guard let cliStreams = cliStreams else {
                throw ExtensionPeerError.unavailable
            }
            return try await CameraCLIEnvironment.$streamEngine.withValue(worker.engine) {
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

    func cancelPendingWork() {
        draining = true
        _ = stopUI()
        worker?.beginDrain()
        cliStreams?.stop()
    }

    func drain() async {
        await worker?.drain()
        await cliStreams?.stopAndWait()
        for task in Array(uiStops.values) { await task.value }
    }

    func prepareDisable() async throws {
        cancelPendingWork()
        await drain()
        if disable == nil {
            let worker = worker
            disable = Task {
                if let worker { try await worker.prepareDisable() }
            }
        }
        do {
            try await disable?.value
        } catch {
            disable = nil
            throw error
        }
    }

    func finishBeforeStop() async {
        cancelPendingWork()
        while true {
            do {
                try await prepareDisable()
                return
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func teardown() async {
        await drain()
        HotKeyRegistrar.shutdown()
        worker?.engine.shutdown()
        worker = nil
        InputFocus.uninstall()
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !draining, worker == nil, let suite = input["defaultsSuite"] as? String,
            suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"],
            let host = input["hostIdentifier"] as? String,
            host == ExtensionEnvironment.values["EDITH_APPLICATION_IDENTIFIER"],
            SurfaceHostContext.current != nil, let defaults = UserDefaults(suiteName: suite)
        else { return false }
        do { worker = try CameraAppWorker(defaults: defaults, host: host) } catch {
            return false
        }
        return true
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !draining, uiStops.isEmpty,
            let defaults = UserDefaults(suiteName: configuration.defaultsSuite),
            let client = configuration.engineClient
        else { return false }
        _ = stopUI(); uiClient = client;
        uiModel = VirtualCameraPageModel(engineClient: client, defaults: defaults)
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost { VirtualCameraPage(model: model) })
    }

    func synchronize() { worker?.installHotKey() }

    func stopUI() -> [Task<Void, Never>] {
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
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
        return Array(uiStops.values)
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
            let hostABI = roleBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String,
            hostABI.hasPrefix("edith-host-")
        else { throw ExtensionPeerError.invalidRequest }
        guard role.lastPathComponent == "app.bundle",
            role.deletingLastPathComponent().lastPathComponent == "virtualCamera"
        else { throw ExtensionPeerError.invalidRequest }
        let package = role.deletingLastPathComponent()
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
            manifest["hostABI"] as? String == hostABI,
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
            carrierBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == hostABI,
            let privilegedBundle = Bundle(url: privileged),
            privilegedBundle.bundleIdentifier
                == "com.pulkit.edith.extensions.virtualCamera.privileged",
            privilegedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == version,
            privilegedBundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == hostABI
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
    private let actions = VirtualCameraActionBridge()
    let manager: VirtualCameraExtensionManager
    private var drainTask: Task<Void, Never>?
    private var microphoneRemoval: Task<Void, Never>?
    private(set) var draining = false
    static let pendingKey = "cameraPendingDisable"

    init(
        defaults: UserDefaults, host: String,
        roleURL: URL = Bundle(for: CameraService.self).bundleURL
    ) throws {
        self.defaults = defaults
        let layout = try CameraSelectedPackageLayout(roleURL: roleURL, hostIdentifier: host)
        guard let bundle = Bundle(url: roleURL) else { throw ExtensionPeerError.invalidRequest }
        source = layout.carrier
        installed = URL(
            fileURLWithPath: "/Applications/Edith Extensions/" + host + ".cameraCarrier.app")
        fixture =
            host.hasPrefix("com.pulkit.edith.tests.")
            && ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        let source = self.source, fixture = self.fixture
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        client = CameraCarrierClient(
            prepare: {
                if fixture { return source }
                let privilege = ExtensionPrivilegedClient(
                    owner: "virtualCamera",
                    source: layout.privileged,
                    version: version)
                try Self.approveCarrier(
                    status: privilege.status,
                    register: { try ExtensionPrivilegedService.service.register() },
                    requestApproval: { try privilege.requestApproval() })
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
                    inherited: ExtensionEnvironment.values,
                    fixture: fixture, selectedSource: source, carrier: carrier)
                try process.run()
                return process
            })
        let client = self.client
        var environment = VirtualCameraEngineEnvironment.live
        if fixture {
            environment.authorization = { .denied }
            environment.sources = { [] }
        }
        let bus = VirtualCameraPreviewBus()
        engine = VirtualCameraEngine(
            edithSink: VirtualCameraSink(extensionIdentifier: host + ".camera"),
            state: VirtualCameraStore.load(defaults), environment: environment, previewBus: bus)
        surface = CameraSurface(engine: engine)
        manager = VirtualCameraExtensionManager(
            environment: .init(
                bundleURL: source,
                hasInstallEntitlement: { fixture || Self.entitledCarrier(source) },
                deviceVisible: {
                    !fixture && VirtualCameraSink(extensionIdentifier: host + ".camera").isInstalled
                },
                canPrepareLocation: true), client: client)
        model = VirtualCameraPageModel(
            defaults: defaults, extensionManager: manager,
            accessProvider: environment.authorization, sourceProvider: environment.sources,
            previewBus: bus,
            requestHandler: { [engine = self.engine] in try await engine.performRecording($0) })
        ui = CameraUICommands(engine: engine, model: model, defaults: defaults)
        draining =
            defaults.bool(forKey: Self.pendingKey)
            || ExtensionEnvironment.values["EDITH_EXTENSION_RECOVERY_ONLY"] == "1"
        if !draining {
            engine.start(); actions.install(engine: engine)
            CameraCLIEnvironment.extensionManager = manager
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
                id: HotKeyCatalog.virtualCamera,
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
        if CameraCLIEnvironment.extensionManager === manager {
            CameraCLIEnvironment.extensionManager = nil
        }
        ui.beginSuspension()
        model.beginSuspension()
        manager.beginSuspension()
        engine.beginSuspension()
        if drainTask == nil {
            drainTask = Task { [self] in
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

    static func approveCarrier(
        status: SMAppService.Status, register: () throws -> Void,
        requestApproval: () throws -> Void
    ) rethrows {
        if status == .notFound { try register() }
        if status != .enabled { try requestApproval() }
    }

    private static func entitledCarrier(_ source: URL) -> Bool {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements[VirtualCameraExtensionManager.installEntitlement] as? Bool == true
    }
}

@MainActor
func makeCameraRuntime() -> ExtensionServiceRuntime {
    ExtensionServiceRuntime(
        id: "virtualCamera", role: "app", bundle: Bundle(for: CameraService.self)
    ) {
        CameraService(runtime: $0)
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeCameraRuntime()).toOpaque())
        })
}
