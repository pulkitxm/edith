import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithLidAwakeExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: LidAwakeWorker?
    private var uiModel: LidAwakeSettingsModel?
    private var uiClient: ExtensionEngineClient?
    private var surface: LidAwakeSurface?
    private let commands = ExtensionCommandRegistry()
    private var applicationQuit: LidAwakeApplicationQuitContext?
    private var stopPrepared = false

    override init() { super.init() }
    init(worker: LidAwakeWorker) { self.worker = worker; super.init() }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let surface = self?.surface else { throw ExtensionPeerError.unavailable }
            if command == "lidAwake.cli.catalog" { return try LidAwakeCLICatalog.data() }
            if command == "lidAwake.cli" {
                guard let worker = self?.worker else { throw ExtensionPeerError.unavailable }
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await LidAwakeCLIExecution.run(request, worker: worker))
            }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        Task {
            do { try await worker?.prepareDisable(); completion(nil) } catch {
                completion(error as NSError)
            }
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "lidAwake", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                SurfaceHostContext.current != nil
            else { return ["ok": false] as NSDictionary }
            if worker == nil {
                let created = LidAwakeWorker(); worker = created
                surface = LidAwakeSurface(worker: created)
            }
        case "prepareApplicationQuit":
            guard worker != nil, !stopPrepared, applicationQuit == nil,
                let context = LidAwakeApplicationQuitContext(input: input)
            else { return ["ok": false] as NSDictionary }
            applicationQuit = context
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client; uiModel = LidAwakeSettingsModel(client: client)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { LidAwakeSettings(model: model) })
        case "synchronize": worker?.engine.syncSettings()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown(); worker?.shutdown(); worker = nil; surface = nil
        case "status": return ["ok": true, "running": worker != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func stopUI() {
        uiModel?.stop(); uiModel = nil
        uiClient?.invalidate(); uiClient = nil
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        guard !stopPrepared else { completion(); return }
        Task {
            await commands.shutdownAndWait()
            var quitPrepared = false
            if let applicationQuit {
                do {
                    try await worker?.prepareApplicationQuit(applicationQuit); quitPrepared = true
                } catch { quitPrepared = false }
            }
            if !quitPrepared {
                while true {
                    do { try await worker?.prepareDisable(); break } catch {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                await worker?.prepareToStop()
            }
            applicationQuit = nil
            stopPrepared = true
            completion()
        }
    }
}

@_cdecl("edith_extension_create")
public func createLidAwakeExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
