import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class BlitzTreeService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var model: BlitzTreeModel?
    private var uiModel: BlitzTreeModel?
    private var uiClient: ExtensionEngineClient?
    private var uiSettings = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var suspended = false

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { model != nil }
    var allowsUIDuringRetirement: Bool { true }

    func start() -> Bool {
        if model == nil { model = BlitzTreeModel() }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let model else { throw ExtensionPeerError.unavailable }
        if command == "surface.snapshot" || command == "surface.perform" {
            return try await SurfaceCommandService.execute(
                providerID: "blitztree", command: command, payload: payload,
                snapshot: { _ in BlitzTreeSurface.snapshot() },
                perform: { _ in throw ExtensionPeerError.invalidRequest })
        }
        return try await BlitzTreeCommands.execute(command, payload: payload, model: model)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiDrains.count < 8, let client = configuration.engineClient else { return false }
        releaseUI()
        uiClient = client
        uiModel = BlitzTreeModel(engineClient: client)
        uiSettings = configuration.isSettings
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !suspended, let model = uiModel else { return nil }
        if uiSettings {
            return NSHostingController(rootView: ExtensionPageHost { BlitzTreeSettings() })
        }
        return NSHostingController(rootView: ExtensionPageHost { BlitzTreePage(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        [releaseUI()]
    }

    func cancelPendingWork() {
        suspended = true
        model?.cancelPendingCommands()
        uiModel?.cancelPendingCommands()
    }

    func drain() async {
        await model?.cancelAndWait()
        await uiModel?.cancelAndWait()
        while let task = uiDrains.values.first { await task.value }
    }

    func teardown() async {
        let release = releaseUI()
        let owner = model
        model = nil
        await release.value
        await owner?.shutdown()
    }

    @discardableResult
    private func releaseUI() -> Task<Void, Never> {
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        uiSettings = false
        let stopping = uiModel
        uiModel = nil
        uiClient?.invalidate()
        uiClient = nil
        stopping?.cancelPendingCommands()
        let id = UUID()
        let task = Task { [self] in
            defer { uiDrains[id] = nil }
            await stopping?.shutdown()
        }
        uiDrains[id] = task
        return task
    }
}

@MainActor
func makeBlitzTreeRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "blitztree", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { BlitzTreeService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeBlitzTreeRuntime()).toOpaque())
        })
}
