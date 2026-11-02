import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class HomebrewService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var surface: HomebrewSurface?
    private var uiModel: HomebrewPageModel?
    private var uiClient: ExtensionEngineClient?
    private var operations: HomebrewEngineCommands?

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var requiresOwnedDataDirectory: Bool { true }
    var isRunning: Bool { operations != nil }

    func start() -> Bool {
        if operations == nil { operations = HomebrewEngineCommands() }
        if surface == nil { surface = HomebrewSurface() }
        return true
    }

    func synchronize() { uiModel?.refreshPreferredKind() }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let surface else { throw ExtensionPeerError.unavailable }
        if command.hasPrefix("homebrew.") {
            guard let operations else { throw ExtensionPeerError.unavailable }
            return try await operations.execute(command, payload: payload)
        }
        return try await SurfaceCommandService.execute(
            providerID: "homebrew", command: command, payload: payload,
            snapshot: { try await surface.snapshot($0) },
            perform: { _ in throw ExtensionPeerError.invalidRequest })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard let client = configuration.engineClient else { return false }
        releaseTextEditing()
        if let model = uiModel {
            if model.isMutating {
                client.invalidate()
            } else {
                uiClient?.invalidate()
                uiClient = client
                model.rebind(client)
            }
        } else {
            uiClient = client
            uiModel = HomebrewPageModel(engineClient: client, memory: .shared)
        }
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost { HomebrewMaintenanceView(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseTextEditing()
        guard let model = uiModel, !model.isMutating else { return [] }
        model.cancelDiscovery()
        uiClient?.invalidate()
        uiClient = nil
        return []
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "cancel" else { return nil }
        return ["ok": true, "cancelled": operations?.cancel() ?? false] as NSDictionary
    }

    func cancelPendingWork() {
        operations?.shutdown()
    }

    func drain() async {
        await operations?.cancelPendingWorkAndWait()
    }

    func teardown() async {
        releaseTextEditing()
        uiModel?.shutdown()
        uiModel = nil
        uiClient?.invalidate()
        uiClient = nil
        surface?.shutdown()
        surface = nil
        let stopping = operations
        operations = nil
        await stopping?.shutdownAndWait()
    }

    private func releaseTextEditing() {
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
    }
}

@MainActor
func makeHomebrewRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "homebrew", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { HomebrewService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeHomebrewRuntime()).toOpaque())
        })
}
