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
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
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

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = model
        let uiOwner = uiModel
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiOwner?.cancelPendingCommands()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await owner?.cancelAndWait()
            await uiOwner?.cancelAndWait()
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = model
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        stopUI()
        model = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            await owner?.shutdown()
        }
        resourceStop = task
        return task
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
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = BlitzTreeModel() }
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client; uiModel = BlitzTreeModel(engineClient: client)
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { BlitzTreePage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        TextEditingCommands.shutdown()
        let model = uiModel; uiModel = nil
        uiClient?.invalidate(); uiClient = nil
        model?.cancelPendingCommands()
        let id = UUID()
        uiDrains[id] = Task { [self] in
            defer { uiDrains[id] = nil }
            await model?.shutdown()
        }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
