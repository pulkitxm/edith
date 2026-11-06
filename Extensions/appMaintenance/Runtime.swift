import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class AppMaintenanceService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var model: AppMaintenanceModel?
    private var uiModel: AppMaintenanceModel?
    private var uiClient: ExtensionEngineClient?
    private(set) var settingsModel: MaintenanceSettingsModel?
    private var uiLocation: String?
    private var uiSection: String?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private let cliStreams = try? ExtensionCLIStreams(owner: "appMaintenance")

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { model != nil }
    var allowsUIDuringRetirement: Bool { true }

    func start() -> Bool {
        if model == nil {
            model = AppMaintenanceModel()
            if ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] == nil {
                model?.startBackgroundDiscovery()
            }
            Task { [weak model] in
                await model?.restoreCachedSnapshot()
            }
        }
        return true
    }

    func synchronize() {
        if let settings = settingsModel { Task { await settings.load() } }
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let model else { throw ExtensionPeerError.unavailable }
        if command == "appMaintenance.cli.catalog" { return try MaintenanceCLICatalog.data() }
        if command.hasPrefix("maintenance.cli.stream.") {
            guard let cliStreams else { throw ExtensionPeerError.unavailable }
            return try cliStreams.invoke(
                MaintenanceCommand.self, operation: command, prefix: "maintenance.cli.stream",
                payload: payload)
        }
        if command == "maintenance.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(try await MaintenanceCLIExecution.run(request))
        }
        if command.hasPrefix("maintenance.ui.") {
            return try await AppMaintenanceUICommands.execute(
                command, payload: payload, model: model)
        }
        if command == "surface.snapshot" || command == "surface.perform" {
            return try await SurfaceCommandService.execute(
                providerID: "appMaintenance", command: command, payload: payload,
                snapshot: { tile in AppMaintenanceSurface.snapshot(model, tile: tile) },
                perform: { action in
                    if action == "refresh" { model.refresh() } else { model.cancel() }
                })
        }
        return try await MaintenanceCommands.execute(command, payload: payload, model: model)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiDrains.count < 8, !configuration.uiOnly,
            let client = configuration.engineClient,
            let location = configuration.location, let section = configuration.section,
            (location == "settings" && section == "extension")
                || (location == "main" && section == "appMaintenance"),
            location != "settings"
                || (configuration.input["tile"] == nil && configuration.input["target"] == nil)
        else { return false }
        releaseUI()
        uiClient = client
        uiLocation = location
        uiSection = section
        if location == "settings" {
            settingsModel = MaintenanceSettingsModel(engine: client)
        } else {
            uiModel = AppMaintenanceModel(engineClient: client, memory: .shared)
        }
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard context.input["location"] as? String == uiLocation,
            context.input["section"] as? String == uiSection
        else { return nil }
        return view(for: presentation)
    }

    func acceptsStopUI(for presentation: UUID?) -> Bool {
        presentation == uiClient?.presentationID
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !runtime.isSuspended, presentation == uiClient?.presentationID else { return nil }
        if let settingsModel {
            return NSHostingController(
                rootView: ExtensionPageHost { AppMaintenanceSettings(model: settingsModel) })
        }
        guard let model = uiModel else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { AppMaintenancePage(model: model) })
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        guard presentation == uiClient?.presentationID else { return [] }
        return releaseUI().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        model?.cancelPendingCommands()
        uiModel?.cancelPendingCommands()
        settingsModel?.stop()
        cliStreams?.stop()
    }

    func drain() async {
        await model?.cancelAndWait()
        await uiModel?.cancelAndWait()
        await settingsModel?.stopAndWait()
        await cliStreams?.stopAndWait()
        while let task = uiDrains.values.first { await task.value }
    }

    func teardown() async {
        let owner = model
        let retirement = releaseUI()
        model = nil
        await owner?.shutdown()
        await retirement?.value
    }

    @discardableResult
    private func releaseUI() -> Task<Void, Never>? {
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        let model = uiModel
        let settings = settingsModel
        settings?.stop()
        model?.cancelPendingCommands()
        var retirement: Task<Void, Never>?
        if model != nil || settings != nil {
            let id = UUID()
            let task = Task { [self, model, settings] in
                defer { uiDrains[id] = nil }
                await model?.shutdown()
                await settings?.stopAndWait()
            }
            uiDrains[id] = task
            retirement = task
        }
        uiModel = nil
        settingsModel = nil
        uiLocation = nil
        uiSection = nil
        uiClient?.invalidate()
        uiClient = nil
        return retirement
    }
}

@MainActor
func makeAppMaintenanceRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "appMaintenance", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { AppMaintenanceService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeAppMaintenanceRuntime()).toOpaque())
        })
}
