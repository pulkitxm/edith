import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class JevService: ExtensionService {
    private var commands: JevCommands?
    private var model: JevSettingsModel?
    private var uiClient: ExtensionEngineClient?
    private var startup: Task<Void, Never>?

    var isRunning: Bool { commands != nil }

    func start() -> Bool {
        if commands == nil {
            let commands = JevCommands()
            self.commands = commands
            startup = Task { _ = await commands.engine.status(probe: false) }
        }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let commands else { throw ExtensionPeerError.rejected("Jev is disabled.") }
        return try await commands.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard let client = configuration.engineClient else { return false }
        releaseUI()
        uiClient = client
        model = JevSettingsModel(engineClient: client)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { JevSettingsPane(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseUI()
        return []
    }

    func cancelPendingWork() {
        startup?.cancel()
        commands?.suspend()
    }

    func drain() async {
        await startup?.value
        startup = nil
        await commands?.drain()
    }

    func teardown() async {
        releaseUI()
        let stopping = commands
        commands = nil
        await stopping?.shutdownAndWait()
    }

    private func releaseUI() {
        model?.shutdown()
        model = nil
        uiClient?.invalidate()
        uiClient = nil
    }
}

@MainActor
func makeJevRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(id: "jev", role: "app", bundle: Bundle(for: BundleAnchor.self)) {
        _ in JevService()
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeJevRuntime()).toOpaque())
        })
}
