import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithAppMaintenanceExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: AppMaintenanceModel?
    private var stopped = false
    private var uiModel: AppMaintenanceModel?
    private var uiClient: ExtensionEngineClient?
    private(set) var settingsModel: MaintenanceSettingsModel?
    private var uiLocation: String?
    private var uiSection: String?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private let commands = ExtensionCommandRegistry()
    private let cliStreams = try? ExtensionCLIStreams(owner: "appMaintenance")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let model = self?.model else { throw ExtensionPeerError.unavailable }
            if command == "appMaintenance.cli.catalog" { return try MaintenanceCLICatalog.data() }
            if command.hasPrefix("maintenance.cli.stream.") {
                guard let cliStreams = self?.cliStreams else {
                    throw ExtensionPeerError.unavailable
                }
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
        let settingsOwner = settingsModel
        let streams = cliStreams
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiOwner?.cancelPendingCommands()
        settingsOwner?.stop()
        streams?.stop()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await owner?.cancelAndWait()
            await uiOwner?.cancelAndWait()
            await settingsOwner?.stopAndWait()
            await streams?.stopAndWait()
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
        stopped = true
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
                "id": "appMaintenance", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard !stopped, let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil {
                model = AppMaintenanceModel()
                if ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] == nil {
                    model?.startBackgroundDiscovery()
                }
                Task { [weak model] in
                    await model?.restoreCachedSnapshot()
                }
            }
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "appMaintenance", !configuration.uiOnly,
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            guard configurePresentation(input, client: client) else {
                return ["ok": false] as NSDictionary
            }
            TextEditingCommands.install()
        case "stopUI":
            guard input["presentationID"] as? String == uiClient?.presentationID.uuidString else {
                return ["ok": false] as NSDictionary
            }
            stopUI()
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard input["presentationID"] as? String == uiClient?.presentationID.uuidString,
                input["location"] as? String == uiLocation,
                input["section"] as? String == uiSection
            else { return ["ok": false] as NSDictionary }
            if let settingsModel {
                return NSHostingController(
                    rootView: ExtensionPageHost { AppMaintenanceSettings(model: settingsModel) })
            }
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { AppMaintenanceView(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    func configurePresentation(_ input: NSDictionary, client: ExtensionEngineClient) -> Bool {
        guard !stopped, input["extensionID"] as? String == "appMaintenance",
            input["uiOnly"] as? Bool == false,
            input["presentationID"] as? String == client.presentationID.uuidString,
            let location = input["location"] as? String, let section = input["section"] as? String,
            (location == "settings" && section == "extension")
                || (location == "main"
                    && (section == "appMaintenance"
                        || AppMaintenanceSection(rawValue: section) != nil))
        else { return false }
        guard location != "settings" || (input["tile"] == nil && input["target"] == nil) else {
            return false
        }
        guard !commandsSuspended, uiDrains.count < 8 else { return false }
        stopUI()
        uiClient = client
        uiLocation = location
        uiSection = section
        if location == "settings" {
            settingsModel = MaintenanceSettingsModel(engine: client)
        } else {
            uiModel = AppMaintenanceModel(engineClient: client, memory: .shared)
        }
        return true
    }

    private func stopUI() {
        ExtensionUIResources.cleanup(of: self, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        let model = uiModel
        let settings = settingsModel
        settings?.stop()
        model?.cancelPendingCommands()
        if model != nil || settings != nil {
            let id = UUID()
            uiDrains[id] = Task { [self, model, settings] in
                defer { uiDrains[id] = nil }
                await model?.shutdown()
                await settings?.stopAndWait()
            }
        }
        uiModel = nil; settingsModel = nil
        uiLocation = nil; uiSection = nil
        uiClient?.invalidate(); uiClient = nil
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
