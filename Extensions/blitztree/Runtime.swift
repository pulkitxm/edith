import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithBlitzTreeExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: BlitzTreeModel?
    private var uiModel: BlitzTreeModel?
    private var uiClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let model = self?.model else { throw ExtensionPeerError.unavailable }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "blitztree", command: command, payload: payload,
                    snapshot: { tile in BlitzTreeSurface.snapshot(model) },
                    perform: { action in
                        switch action {
                        case "choose": model.chooseFolder()
                        case "rescan":
                            guard let root = model.root else {
                                throw ExtensionPeerError.invalidRequest
                            }; model.scan(root, remember: false)
                        case "cancel": model.cancel()
                        default: throw ExtensionPeerError.invalidRequest
                        }
                    })
            }
            return try await BlitzTreeCommands.execute(command, payload: payload, model: model)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            await model?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "blitztree", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = BlitzTreeModel() }
            TextEditingCommands.install()
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client; uiModel = BlitzTreeModel(engineClient: client)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { BlitzTreePage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            model = nil
            TextEditingCommands.shutdown()
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        let model = uiModel; uiModel = nil
        uiClient?.invalidate(); uiClient = nil
        Task { await model?.shutdown() }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
