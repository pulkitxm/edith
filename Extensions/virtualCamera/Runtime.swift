import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Security
import SwiftUI

@MainActor @objc(EdithCameraExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: CameraAppWorker?
    private let commands = ExtensionCommandRegistry()
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
                switch values["operation"] {
                case "activate": try await worker.client.activate()
                case "deactivate": try await worker.client.deactivate()
                case "microphone": try await worker.client.prepareMicrophone()
                default: throw ExtensionPeerError.invalidRequest
                }
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
            await self?.worker?.drain(); completion()
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
        case "view":
            guard let worker else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    if worker.draining {
                        PageScaffold {
                            PageHeader("Camera")
                        } content: {
                            Text(
                                "Camera is waiting for its system resources to be released. Restart macOS if requested, then finish disabling it in Extensions."
                            )
                        }
                    } else {
                        VirtualCameraPage(model: worker.model)
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
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
}

@MainActor final class CameraAppWorker {
    let engine: VirtualCameraEngine
    let model: VirtualCameraPageModel
    let client: CameraCarrierClient
    let surface: CameraSurface
    private let defaults: UserDefaults
    private let source: URL
    private let installed: URL
    private let fixture: Bool
    private let actions = VirtualCameraActionBridge()
    private let manager: VirtualCameraExtensionManager
    private var drainTask: Task<Void, Never>?
    private(set) var draining = false
    static let pendingKey = "cameraPendingDisable"

    init(defaults: UserDefaults, host: String) {
        self.defaults = defaults
        let bundle = Bundle(for: ExtensionRuntime.self)
        let directory = bundle.bundleURL.deletingLastPathComponent()
        source = directory.appendingPathComponent("CameraCarrier.app")
        installed = URL(
            fileURLWithPath: "/Applications/Edith Extensions/" + host + ".cameraCarrier.app")
        fixture =
            host.hasPrefix("com.pulkit.edith.tests.")
            && ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        let source = self.source, fixture = self.fixture
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
                process.standardError = FileHandle.nullDevice
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
            environment.authorization = { .denied }; environment.obsRunning = { false }
            environment.frontmostApplication = { nil }; environment.sources = { [] }
        }
        environment.prepareMicrophone = { try await client.prepareMicrophone() }
        let bus = VirtualCameraPreviewBus()
        engine = VirtualCameraEngine(
            state: VirtualCameraStore.load(defaults), environment: environment, previewBus: bus)
        surface = CameraSurface(engine: engine)
        manager = VirtualCameraExtensionManager(
            environment: .init(
                bundleURL: source,
                hasInstallEntitlement: { fixture || Self.entitledCarrier(source) },
                deviceVisible: {
                    fixture
                        ? false
                        : VirtualCameraSink(extensionIdentifier: host + ".camera").isInstalled
                },
                canPrepareLocation: true), client: client)
        model = VirtualCameraPageModel(
            defaults: defaults, extensionManager: manager,
            accessProvider: environment.authorization, sourceProvider: environment.sources,
            previewBus: bus)
        draining =
            defaults.bool(forKey: Self.pendingKey)
            || ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"] == "1"
        if !draining {
            engine.start(); actions.install(engine: engine)
            CameraExtensionBridge.install(manager: manager)
        }
    }

    func markDraining() { draining = true }

    func drain() async {
        draining = true
        if drainTask == nil {
            drainTask = Task { [self] in
                CameraExtensionBridge.shutdown()
                await actions.shutdown()
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

    private static func entitledCarrier(_ source: URL) -> Bool {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let values = info as? [String: Any],
            let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements[VirtualCameraExtensionManager.installEntitlement] as? Bool == true
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
