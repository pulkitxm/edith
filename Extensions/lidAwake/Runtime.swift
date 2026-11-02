import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class LidAwakeService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: LidAwakeWorker?
    private var uiModel: LidAwakeSettingsModel?
    private var uiClient: ExtensionEngineClient?
    private var surface: LidAwakeSurface?
    private var applicationQuit: LidAwakeApplicationQuitContext?
    private var uiRetirements: [UUID: Task<Void, Never>] = [:]

    init(runtime: ExtensionServiceRuntime, worker: LidAwakeWorker? = nil) {
        self.runtime = runtime
        self.worker = worker
    }

    var isRunning: Bool { worker != nil }
    var preparesForDisable: Bool { true }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard SurfaceHostContext.current != nil else { return false }
        if worker == nil {
            let created = LidAwakeWorker()
            worker = created
            surface = LidAwakeSurface(worker: created)
        }
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        worker?.engine.syncSettings()
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let surface else { throw ExtensionPeerError.unavailable }
        if command == "lidAwake.cli.catalog" { return try LidAwakeCLICatalog.data() }
        if command == "lidAwake.cli" {
            guard let worker else { throw ExtensionPeerError.unavailable }
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await LidAwakeCLIExecution.run(request, worker: worker))
        }
        return try await surface.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiRetirements.isEmpty, let client = configuration.engineClient else { return false }
        _ = retireUI()
        uiClient = client
        uiModel = LidAwakeSettingsModel(client: client)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { LidAwakeSettings(model: model) })
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        retireUI().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        worker?.beginCommandDrain()
        uiModel?.beginCommandDrain()
    }

    func drain() async {
        await worker?.cancelPendingWorkAndWait()
        await uiModel?.stopAndWait()
        for task in Array(uiRetirements.values) { await task.value }
    }

    func prepareDisable() async throws {
        try await worker?.prepareDisable()
    }

    func teardown() async {
        var quitPrepared = false
        if let applicationQuit {
            do {
                try await worker?.prepareApplicationQuit(applicationQuit)
                quitPrepared = true
            } catch { quitPrepared = false }
        }
        if !quitPrepared {
            while true {
                do {
                    try await worker?.prepareDisable()
                    break
                } catch {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await worker?.prepareToStop()
        }
        await retireUI()?.value
        for task in Array(uiRetirements.values) { await task.value }
        applicationQuit = nil
        worker = nil
        surface = nil
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "prepareApplicationQuit" else { return nil }
        guard worker != nil, !runtime.isStopping, applicationQuit == nil,
            let quit = LidAwakeApplicationQuitContext(input: context)
        else { return ["ok": false] as NSDictionary }
        applicationQuit = quit
        return ["ok": true] as NSDictionary
    }

    private func retireUI() -> Task<Void, Never>? {
        let model = uiModel
        model?.stop()
        uiModel = nil
        uiClient?.invalidate()
        uiClient = nil
        guard let model else { return nil }
        let id = UUID()
        let task = Task { [self, model] in
            await model.stopAndWait()
            uiRetirements[id] = nil
        }
        uiRetirements[id] = task
        return task
    }
}

@MainActor
func makeLidAwakeRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "lidAwake", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { LidAwakeService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createLidAwakeExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeLidAwakeRuntime()).toOpaque())
        })
}
