import EdithExtensionSupport
import Foundation

@MainActor
enum MaintenanceCommands {
    static func execute(_ command: String, payload: Data, model: AppMaintenanceModel) async throws
        -> Data
    {
        guard !model.stopped else { throw ExtensionPeerError.unavailable }
        switch command {
        case "maintenance.status": return try status(model)
        case "maintenance.inventory": return try JSONEncoder().encode(model.applications)
        case "maintenance.refresh":
            guard !model.mutationInProgress else {
                throw ExtensionPeerError.rejected("An operation is already running.")
            }
            return try await perform(model) { model.refresh() }
        case "maintenance.preview": return try preview(model)
        case "maintenance.scan":
            let request = try decode(MaintenanceItemRequest.self, payload)
            guard !model.mutationInProgress,
                let application = model.applications.first(where: { $0.id == request.id })
            else { throw ExtensionPeerError.invalidRequest }
            return try await perform(model) { model.select(application) }
        case "maintenance.selection":
            let request = try decode(MaintenanceSelectionRequest.self, payload)
            guard model.phase == .ready, !model.checkingUpdates else {
                throw ExtensionPeerError.invalidRequest
            }
            let selected = Set(request.ids)
            if request.kind == "items" {
                guard let plan = model.plan, selected.isSubset(of: Set(plan.items.map(\.id))) else {
                    throw ExtensionPeerError.invalidRequest
                }
                model.selectedItemIDs = selected
            } else if request.kind == "updates" {
                guard selected.isSubset(of: Set(model.updates.map(\.id))) else {
                    throw ExtensionPeerError.invalidRequest
                }
                model.selectedUpdateIDs = selected
            } else {
                throw ExtensionPeerError.invalidRequest
            }
            return try preview(model)
        case "maintenance.remove":
            let request = try decode(MaintenanceConfirmation.self, payload)
            try validate(request, model: model)
            guard model.plan != nil, !model.selectedItems.isEmpty else {
                throw ExtensionPeerError.invalidRequest
            }
            return try await perform(model) { model.removeSelected() }
        case "maintenance.updates": return try JSONEncoder().encode(model.updates)
        case "maintenance.history": return try JSONEncoder().encode(model.updateHistory)
        case "maintenance.update":
            let request = try decode(MaintenanceUpdateRequest.self, payload)
            try validate(request.confirmation, model: model)
            guard (1...8).contains(request.concurrency), (0...3).contains(request.retries),
                model.updates.contains(where: { model.selectedUpdateIDs.contains($0.id) })
            else { throw ExtensionPeerError.invalidRequest }
            return try await perform(model) {
                model.runSelectedUpdates(concurrency: request.concurrency, retries: request.retries)
            }
        case "maintenance.install.preview":
            let request = try decode(MaintenanceImageRequest.self, payload)
            guard !model.mutationInProgress, request.path.hasPrefix("/"),
                !request.path.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            return try await perform(model) {
                model.prepareDiskImage(
                    URL(fileURLWithPath: request.path), destination: request.destination)
            }
        case "maintenance.install":
            let request = try decode(MaintenanceInstallRequest.self, payload)
            try validate(request.confirmation, model: model)
            guard model.installPlan != nil else { throw ExtensionPeerError.invalidRequest }
            return try await perform(model) {
                model.installDiskImage(
                    replaceExisting: request.replaceExisting,
                    moveImageToTrash: request.moveImageToTrash)
            }
        case "maintenance.ignore", "maintenance.exclude", "maintenance.snooze":
            let request = try decode(MaintenancePolicyRequest.self, payload)
            guard !model.mutationInProgress,
                let item = model.updates.first(where: { $0.id == request.id })
            else { throw ExtensionPeerError.invalidRequest }
            if command == "maintenance.ignore" {
                model.ignore(item)
            } else if command == "maintenance.exclude" {
                model.exclude(item)
            } else {
                guard let seconds = request.seconds, seconds.isFinite,
                    (1...31_536_000).contains(seconds)
                else { throw ExtensionPeerError.invalidRequest }
                model.snooze(item, until: Date().addingTimeInterval(seconds))
            }
            return try status(model)
        case "maintenance.reset":
            guard !model.mutationInProgress else { throw ExtensionPeerError.invalidRequest }
            return try await perform(model) { model.resetUpdatePolicies() }
        case "maintenance.backup-updates":
            let request = try decode(MaintenanceBackupRequest.self, payload)
            guard request.path.hasPrefix("/"), !request.path.utf8.contains(0) else {
                throw ExtensionPeerError.invalidRequest
            }
            try model.backupUpdates(to: URL(fileURLWithPath: request.path))
            return Data("{\"saved\":true}".utf8)
        default: throw ExtensionPeerError.rejected("App Maintenance does not support this command.")
        }
    }

    private static func perform(_ model: AppMaintenanceModel, _ action: () -> Void) async throws
        -> Data
    {
        try await withTaskCancellationHandler {
            action()
            await model.finishWork()
            try Task.checkCancellation()
            if let error = model.errorMessage { throw ExtensionPeerError.rejected(error) }
            return try preview(model)
        } onCancel: {
            Task { @MainActor in model.cancel() }
        }
    }

    private static func validate(
        _ confirmation: MaintenanceConfirmation, model: AppMaintenanceModel
    ) throws {
        guard confirmation.confirmed, confirmation.previewToken == model.previewToken,
            model.phase == .ready, !model.checkingUpdates, !model.mutationInProgress
        else {
            throw ExtensionPeerError.rejected("Confirm a current preview before making changes.")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw ExtensionPeerError.invalidRequest
        }
        return value
    }

    private static func status(_ model: AppMaintenanceModel) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "enabled": !model.stopped, "working": model.ownedOperationCount > 0,
            "applications": model.applications.count, "updates": model.updates.count,
        ])
    }

    private static func preview(_ model: AppMaintenanceModel) throws -> Data {
        var values: [String: Any] = [
            "previewToken": model.previewToken.uuidString,
            "working": model.ownedOperationCount > 0,
            "applicationID": model.selectedApplicationID as Any? ?? NSNull(),
            "items": model.selectedItems.map {
                ["id": $0.id, "path": $0.url.path, "bytes": $0.sizeBytes] as [String: Any]
            },
            "selectedUpdateIDs": Array(model.selectedUpdateIDs).sorted(),
        ]
        if let plan = model.installPlan {
            values["installation"] = [
                "source": plan.sourceApplication.url.path, "destination": plan.destinationURL.path,
                "replacesExisting": plan.existingApplication != nil,
            ]
        }
        return try JSONSerialization.data(withJSONObject: values)
    }
}

private struct MaintenanceItemRequest: Decodable { let id: String }
private struct MaintenanceConfirmation: Decodable { let confirmed: Bool; let previewToken: UUID }
private struct MaintenanceUpdateRequest: Decodable {
    let confirmed: Bool; let previewToken: UUID; let concurrency: Int; let retries: Int
    var confirmation: MaintenanceConfirmation {
        MaintenanceConfirmation(confirmed: confirmed, previewToken: previewToken)
    }
}
private struct MaintenanceInstallRequest: Decodable {
    let confirmed: Bool; let previewToken: UUID; let replaceExisting: Bool;
    let moveImageToTrash: Bool
    var confirmation: MaintenanceConfirmation {
        MaintenanceConfirmation(confirmed: confirmed, previewToken: previewToken)
    }
}
private struct MaintenanceImageRequest: Decodable {
    let path: String; let destination: AppMaintenanceInstallDestination
}
private struct MaintenancePolicyRequest: Decodable { let id: String; let seconds: Double? }
private struct MaintenanceBackupRequest: Decodable { let path: String }

private struct MaintenanceSelectionRequest: Decodable { let kind: String; let ids: [String] }
