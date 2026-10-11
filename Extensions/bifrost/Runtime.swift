import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithBifrostExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: BifrostWorker?
    private var uiContext: BifrostUIContext?
    private var engineClient: ExtensionEngineClient?
    private var surface: BifrostSurface?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?
    private var stopped = false
    private var activeCalls = 0
    private var commandDrain: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, !self.stopped, let worker = self.worker, let surface = self.surface
            else {
                throw ExtensionPeerError.unavailable
            }
            self.activeCalls += 1
            defer { self.activeCalls -= 1 }
            if command.hasPrefix("bifrost.cli.") {
                if self.cliStreams == nil {
                    self.cliStreams = try ExtensionCLIStreams(owner: "bifrost")
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try await BifrostCLIExecution.stream(
                    streams, operation: command, payload: payload, store: worker.store)
            }
            if command == "bifrost.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await BifrostCLIExecution.run(request, store: worker.store))
            }
            if command.hasPrefix("bifrost.ui.") {
                return try BifrostUIContext.execute(command, payload: payload, worker: worker)
            }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = worker
        let uiOwner = uiContext
        let streams = cliStreams
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiOwner?.stop()
        streams?.stop()
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await owner?.drain()
            await streams?.stopAndWait()
            await uiOwner?.stopAndWait()
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        let drain = beginCommandDrain()
        let owner = worker
        Task { [self] in
            await drain.value
            do { try await owner?.prepareDisable(); completion(nil) } catch {
                completion(error as NSError)
            }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        stopped = true
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown()
        let stopping = worker
        stopping?.shutdown()
        Task { [self] in
            await drain.value
            await stopping?.drain()
            while activeCalls > 0 { await Task.yield() }
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            completion()
        }
    }

    private func retireUI() {
        guard let owner = uiContext else { return }
        owner.stop()
        let id = UUID()
        uiDrains[id] = Task { [self, owner] in
            defer { uiDrains[id] = nil }
            await owner.stopAndWait()
            owner.shutdown()
        }
        uiContext = nil; BifrostUIContext.current = nil
        engineClient?.invalidate(); engineClient = nil
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "bifrost", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "bifrost", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            let context = BifrostUIContext(client: client)
            uiContext = context; BifrostUIContext.current = context
            TextEditingCommands.install()
        case "stopUI":
            retireUI()
            TextEditingCommands.shutdown()
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard !stopped, let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                SurfaceHostContext.current != nil
            else { return ["ok": false] as NSDictionary }
            if worker == nil {
                let created = BifrostWorker(); worker = created;
                surface = BifrostSurface(store: created.store)
            }
            if ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"] != "1" {
                TextEditingCommands.install()
            }
        case "view":
            guard let context = uiContext else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { BifrostSettings(context: context) })
        case "synchronize": worker?.configureHotKey()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            prepareToStop(completion: {}); worker = nil; surface = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
        case "status": return ["ok": true, "running": !stopped && worker != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createBifrostExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
