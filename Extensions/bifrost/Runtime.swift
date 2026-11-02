import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class BifrostService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: BifrostWorker?
    private var uiContext: BifrostUIContext?
    private var engineClient: ExtensionEngineClient?
    private var surface: BifrostSurface?
    private var cliStreams: ExtensionCLIStreams?
    private var activeCalls = 0
    private var uiDrains: [UUID: Task<Void, Never>] = [:]

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { worker != nil }
    var allowsUIDuringRetirement: Bool { true }
    var preparesForDisable: Bool { true }

    func prepareDisable() async throws {
        try await worker?.prepareDisable()
    }

    func start() -> Bool {
        guard SurfaceHostContext.current != nil else { return false }
        if worker == nil {
            let created = BifrostWorker()
            worker = created
            surface = BifrostSurface(store: created.store)
        }
        if ExtensionEnvironment.values["EDITH_EXTENSION_RECOVERY_ONLY"] != "1" {
            TextEditingCommands.install()
        }
        return true
    }

    func synchronize() {
        guard !runtime.isSuspended else { return }
        worker?.configureHotKey()
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker, let surface else { throw ExtensionPeerError.unavailable }
        activeCalls += 1
        defer { activeCalls -= 1 }
        if command == "bifrost.cli.catalog" {
            return try ExtensionCLICatalog.data(
                BifrostCLICommand.self, owner: "bifrost", payload: payload, streaming: true)
        }
        if command.hasPrefix("bifrost.cli.") {
            if cliStreams == nil {
                cliStreams = try ExtensionCLIStreams(owner: "bifrost")
            }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
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

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiDrains.count < 8, engineClient == nil, let client = configuration.engineClient
        else { return false }
        engineClient = client
        let context = BifrostUIContext(client: client)
        uiContext = context
        BifrostUIContext.current = context
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !runtime.isSuspended, let context = uiContext else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost { BifrostSettings(context: context) })
    }

    func stopUI() -> [Task<Void, Never>] {
        let retirement = retireUI()
        releaseTextEditing()
        return retirement.map { [$0] } ?? []
    }

    func cancelPendingWork() {
        worker?.cancelPendingCommands()
        uiContext?.stop()
        cliStreams?.stop()
    }

    func drain() async {
        let owner = worker
        let streams = cliStreams
        let uiOwner = uiContext
        await owner?.drain()
        await streams?.stopAndWait()
        await uiOwner?.stopAndWait()
    }

    func teardown() async {
        let owner = worker
        let streams = cliStreams
        let retirement = retireUI()
        worker = nil
        surface = nil
        cliStreams = nil
        owner?.shutdown()
        await owner?.drain()
        await streams?.stopAndWait()
        await retirement?.value
        while activeCalls > 0 { await Task.yield() }
        releaseTextEditing()
        InputFocus.uninstall()
    }

    private func retireUI() -> Task<Void, Never>? {
        guard let owner = uiContext else { return nil }
        owner.stop()
        let id = UUID()
        let retirement = Task { [self] in
            defer { uiDrains[id] = nil }
            await owner.stopAndWait()
            owner.shutdown()
        }
        uiDrains[id] = retirement
        uiContext = nil
        if BifrostUIContext.current === owner { BifrostUIContext.current = nil }
        engineClient?.invalidate()
        engineClient = nil
        return retirement
    }

    private func releaseTextEditing() {
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
    }
}

@MainActor
func makeBifrostRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "bifrost", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { BifrostService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createBifrostExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeBifrostRuntime()).toOpaque())
        })
}
