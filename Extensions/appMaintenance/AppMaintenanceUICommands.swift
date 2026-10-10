import AppKit
import EdithExtensionSupport
import Foundation

typealias MaintenancePackagePreference = @MainActor (String, Data) async throws -> Data

struct MaintenanceUISettings: Codable, Equatable {
    var installDestination = AppMaintenanceInstallDestination.user.rawValue
    var autoRefresh = false
    var notifications = true
    var refreshInterval = 86_400.0
    var concurrency = 2
    var retries = 1
    static func load(_ defaults: UserDefaults) -> Self {
        .init(
            installDestination: defaults.string(forKey: MaintenancePreferences.installDestination)
                ?? AppMaintenanceInstallDestination.user.rawValue,
            autoRefresh: defaults.bool(forKey: MaintenancePreferences.updateAutoRefresh),
            notifications: defaults.object(forKey: MaintenancePreferences.updateNotifications)
                as? Bool ?? true,
            refreshInterval: defaults.object(forKey: MaintenancePreferences.updateRefreshInterval)
                as? Double ?? 86_400,
            concurrency: defaults.object(forKey: MaintenancePreferences.updateConcurrency) as? Int
                ?? 2,
            retries: defaults.object(forKey: MaintenancePreferences.updateRetries) as? Int ?? 1)
    }
    func save(_ defaults: UserDefaults) throws {
        guard AppMaintenanceInstallDestination(rawValue: installDestination) != nil,
            refreshInterval.isFinite, (900...31_536_000).contains(refreshInterval),
            (1...8).contains(concurrency), (0...3).contains(retries)
        else { throw ExtensionPeerError.invalidRequest }
        defaults.set(installDestination, forKey: MaintenancePreferences.installDestination)
        defaults.set(autoRefresh, forKey: MaintenancePreferences.updateAutoRefresh)
        defaults.set(notifications, forKey: MaintenancePreferences.updateNotifications)
        defaults.set(refreshInterval, forKey: MaintenancePreferences.updateRefreshInterval)
        defaults.set(concurrency, forKey: MaintenancePreferences.updateConcurrency)
        defaults.set(retries, forKey: MaintenancePreferences.updateRetries)
    }
}
struct AppMaintenanceUISnapshot: Codable {
    let preferences: MaintenanceUISettings
    let icons: [String: Data]
    let applications: [InstalledApplication]
    let previewToken: UUID
    let selectedApplicationID: String?
    let plan: AppMaintenancePlan?
    let selectedItemIDs: Set<String>
    let phase: AppMaintenanceModel.Phase
    let errorMessage: String?
    let resultMessage: String?
    let installPlan: AppMaintenanceDiskImagePlan?
    let updates: [AppUpdateItem]
    let updateHistory: [AppUpdateResult]
    let selectedUpdateIDs: Set<String>
    let focusedUpdateID: String?
    let lastUpdateRefresh: Date?
    let checkingUpdates: Bool
}
struct AppMaintenanceUIAction: Codable {
    let operation: String; let value: String?; let item: String?; let enabled: Bool?
    let integer: Int?; let number: Double?; let previewToken: UUID
}
@MainActor enum AppMaintenanceUICommands {
    static func execute(
        _ command: String, payload: Data, model: AppMaintenanceModel,
        packagePreference: MaintenancePackagePreference = { command, payload in
            guard let endpoint = ExtensionPeerEndpoint.current(owner: "homebrew") else {
                throw ExtensionPeerError.unavailable
            }
            return try await endpoint.invoke(command, payload: payload)
        }
    ) async throws
        -> Data
    {
        try Task.checkCancellation()
        guard payload.count <= 65_536, !model.stopped else { throw ExtensionPeerError.unavailable }
        if command == "maintenance.ui.settings.read" {
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(MaintenanceUISettings.load(model.preferenceDefaults))
        }
        if command == "maintenance.ui.settings.write" {
            let settings = try JSONDecoder().decode(MaintenanceUISettings.self, from: payload)
            try settings.save(model.preferenceDefaults)
            model.preferences = settings
            return try JSONEncoder().encode(settings)
        }
        if command == "maintenance.ui.packageKind.read"
            || command == "maintenance.ui.packageKind.write"
        {
            let values = try JSONDecoder().decode([String: String].self, from: payload)
            let writing = command == "maintenance.ui.packageKind.write"
            guard
                writing
                    ? (Set(values.keys) == ["kind"]
                        && ["formula", "cask"].contains(values["kind"] ?? "")) : values.isEmpty
            else {
                throw ExtensionPeerError.invalidRequest
            }
            let data = try await packagePreference(
                writing ? "homebrew.preference.write" : "homebrew.preference.read", payload)
            try Task.checkCancellation()
            guard !model.stopped, let kind = try? JSONDecoder().decode(String.self, from: data),
                ["formula", "cask"].contains(kind)
            else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(kind)
        }
        if command == "maintenance.ui.snapshot" {
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
        } else if command == "maintenance.ui.preferences" {
            let preferences = try JSONDecoder().decode(MaintenanceUISettings.self, from: payload)
            try preferences.save(model.preferenceDefaults); model.preferences = preferences
        } else if command == "maintenance.ui.action" {
            let request = try JSONDecoder().decode(AppMaintenanceUIAction.self, from: payload)
            if ["remove", "update", "install", "selection", "updateSelection"].contains(
                request.operation)
            {
                guard request.previewToken == model.previewToken, !model.mutationInProgress,
                    model.phase == .ready
                else {
                    throw ExtensionPeerError.rejected(
                        "Review the current plan before making changes.")
                }
            }
            switch request.operation {
            case "reveal":
                guard let path = request.value, model.visiblePaths.contains(path) else {
                    throw ExtensionPeerError.invalidRequest
                }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            case "refresh":
                guard let interval = request.number, interval.isFinite,
                    (1...31_536_000).contains(interval)
                else { throw ExtensionPeerError.invalidRequest }
                model.refresh(automatic: request.enabled == true, interval: interval)
            case "cancel": model.cancel()
            case "cancelImage": model.cancelInstallPlan()
            case "select":
                guard let id = request.value,
                    let app = model.applications.first(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                model.select(app)
            case "selection":
                guard let id = request.value, let selected = request.enabled,
                    let item = model.plan?.items.first(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                model.setSelected(selected, item: item)
            case "updateSelection":
                guard let id = request.value, let selected = request.enabled,
                    let item = model.updates.first(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                model.setUpdateSelected(selected, item: item)
            case "remove": model.removeSelected()
            case "update":
                guard let concurrency = request.integer, (1...8).contains(concurrency),
                    let retries = request.number, retries.isFinite, retries.rounded() == retries,
                    (0...3).contains(retries)
                else { throw ExtensionPeerError.invalidRequest }
                model.runSelectedUpdates(concurrency: concurrency, retries: Int(retries))
            case "prepareImage":
                guard let path = request.value, path.hasPrefix("/"), !path.utf8.contains(0),
                    let raw = request.item,
                    let destination = AppMaintenanceInstallDestination(rawValue: raw)
                else { throw ExtensionPeerError.invalidRequest }
                model.prepareDiskImage(URL(fileURLWithPath: path), destination: destination)
            case "install":
                guard let replace = request.enabled, let trash = request.integer,
                    [0, 1].contains(trash), model.installPlan != nil
                else { throw ExtensionPeerError.invalidRequest }
                model.installDiskImage(replaceExisting: replace, moveImageToTrash: trash == 1)
            case "ignore", "snooze", "exclude":
                guard !model.mutationInProgress, let id = request.value,
                    let item = model.updates.first(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                if request.operation == "ignore" {
                    model.ignore(item)
                } else if request.operation == "exclude" {
                    model.exclude(item)
                } else {
                    guard let until = request.number, until.isFinite,
                        until > Date().timeIntervalSince1970,
                        until < Date().timeIntervalSince1970 + 31_536_000
                    else { throw ExtensionPeerError.invalidRequest }
                    model.snooze(item, until: Date(timeIntervalSince1970: until))
                }
            case "reset": model.resetUpdatePolicies()
            case "openExtension":
                guard let id = request.value, ["homebrew", "cleaner", "blitztree"].contains(id)
                else { throw ExtensionPeerError.invalidRequest }
                model.openExtension(id)
            default: throw ExtensionPeerError.invalidRequest
            }
        } else {
            throw ExtensionPeerError.invalidRequest
        }
        return try JSONEncoder().encode(model.uiSnapshot())
    }
}
