import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class CleanerService: ExtensionService {
    private var model: CleanerModel?
    private var uiModel: CleanerModel?
    private var uiClient: ExtensionEngineClient?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var suspended = false
    private let cliStreams = try? ExtensionCLIStreams(owner: "cleaner")

    var isRunning: Bool { model != nil }
    var allowsUIDuringRetirement: Bool { true }

    func start() -> Bool {
        if model == nil {
            model = CleanerModel()
            if ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] == nil {
                model?.startBackgroundEstimates()
            }
        }
        return true
    }

    func synchronize() { uiModel?.reloadPreferences() }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let model else { throw ExtensionPeerError.unavailable }
        if command == "cleaner.cli.catalog" { return try CleanerCLICatalog.data() }
        if command.hasPrefix("cleaner.cli.stream.") {
            guard let cliStreams else { throw ExtensionPeerError.unavailable }
            return try cliStreams.invoke(
                CleanerCommand.self, operation: command, prefix: "cleaner.cli.stream",
                payload: payload)
        }
        if command == "cleaner.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(try await CleanerCLIExecution.run(request))
        }
        if command.hasPrefix("cleaner.ui.") {
            return try await CleanerUICommands.execute(command, payload: payload, model: model)
        }
        if command == "surface.snapshot" || command == "surface.perform" {
            return try await SurfaceCommandService.execute(
                providerID: "cleaner", command: command, payload: payload,
                snapshot: { tile in CleanerSurface.snapshot(model) },
                perform: { action in
                    if action == "scan" { model.scan() } else { model.cancelScan() }
                })
        }
        return try await CleanerCommands.execute(command, payload: payload, model: model)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiDrains.count < 8, let client = configuration.engineClient,
            let defaults = UserDefaults(suiteName: configuration.defaultsSuite)
        else { return false }
        releaseUI()
        uiClient = client
        uiModel = CleanerModel(engineClient: client, defaults: defaults)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !suspended, let model = uiModel else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { CleanerPage(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        [releaseUI()]
    }

    func cancelPendingWork() {
        suspended = true
        model?.cancelPendingCommands()
        uiModel?.cancelPendingCommands()
        cliStreams?.stop()
    }

    func drain() async {
        await model?.cancelAndWait()
        await uiModel?.cancelAndWait()
        await cliStreams?.stopAndWait()
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
func makeCleanerRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "cleaner", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in CleanerService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeCleanerRuntime()).toOpaque())
        })
}
