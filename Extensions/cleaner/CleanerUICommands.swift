import EdithExtensionSupport
import Foundation

struct CleanerUISnapshot: Codable {
    let previewToken: UUID
    let categories: [JunkCategory]
    let scanning: Bool
    let scanned: Bool
    let logs: [String]
    let lastReclaimed: Int64
    let drives: [DriveInfo]
    let driveOptions: [DriveInfo]
    let customFolders: [String]
    let driveSelection: Set<String>?
    let operationTitle: String
    let loadingDriveOptions: Bool
    let filters: CleanerFilters
}
struct CleanerUIAction: Codable {
    let operation: String; let value: String?; let item: String?; let previewToken: UUID
    var search: String? = nil
    var known: Int? = nil
    var knownSelection: Int? = nil
}
struct CleanerUISnapshotRequest: Codable {
    let known: Int?
    var knownSelection: Int? = nil
}
struct CleanerUIReply: Codable {
    let stamp: Int
    let snapshot: CleanerUISnapshot?
    let selectionStamp: Int
    let selection: CleanerSelection?

    @MainActor init(model: CleanerModel, known: Int?, knownSelection: Int?) {
        stamp = model.uiStamp
        snapshot = known == model.uiStamp ? nil : model.uiSnapshot()
        selectionStamp = model.selectionRevision
        selection = knownSelection == model.selectionRevision ? nil : model.selection
    }
}
@MainActor enum CleanerUICommands {
    static func execute(_ command: String, payload: Data, model: CleanerModel) async throws -> Data
    {
        guard !model.stopped else { throw ExtensionPeerError.unavailable }
        if command == "cleaner.ui.snapshot" {
            guard payload.count <= 128,
                let request = try? JSONDecoder().decode(
                    CleanerUISnapshotRequest.self, from: payload)
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                CleanerUIReply(
                    model: model, known: request.known, knownSelection: request.knownSelection))
        } else if command == "cleaner.ui.action" {
            let action = try JSONDecoder().decode(CleanerUIAction.self, from: payload)
            let selection = ["all", "category", "item"].contains(action.operation)
            if selection {
                guard action.previewToken == model.previewToken, !model.scanning, model.scanned
                else {
                    throw ExtensionPeerError.rejected(
                        "Review a current scan before changing its selection.")
                }
            }
            let mirrored = selection && action.knownSelection == model.selectionRevision
            let search = action.search ?? ""
            guard search.utf8.count <= 1_024 else { throw ExtensionPeerError.invalidRequest }
            switch action.operation {
            case "scan": model.scan()
            case "cancel": model.cancelScan()
            case "drives": model.loadDriveOptions()
            case "all": model.toggleAll(matching: search)
            case "category":
                guard let id = action.value, model.categories.contains(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                model.toggleCategory(id, matching: search)
            case "item":
                guard let category = action.value, let item = action.item,
                    model.categories.first(where: { $0.id == category })?.items.contains(where: {
                        $0.id == item
                    }) == true
                else { throw ExtensionPeerError.invalidRequest }
                model.toggleItem(categoryID: category, itemID: item)
            case "drive":
                guard let id = action.value,
                    model.driveOptions.contains(where: { $0.id == id })
                        || model.customFolders.contains(id)
                else { throw ExtensionPeerError.invalidRequest }
                model.toggleDrive(id)
            case "addFolder", "removeFolder":
                guard let path = action.value, path.hasPrefix("/"), !path.utf8.contains(0) else {
                    throw ExtensionPeerError.invalidRequest
                }
                if action.operation == "addFolder" {
                    model.addCustomFolder(path)
                } else {
                    model.removeCustomFolder(path)
                }
            case "filters":
                guard let value = action.value, value.utf8.count <= 1_024,
                    let filters = try? JSONDecoder().decode(
                        CleanerFilters.self, from: Data(value.utf8))
                else { throw ExtensionPeerError.invalidRequest }
                model.updateFilters(filters)
            case "clean":
                guard action.previewToken == model.previewToken, !model.scanning, model.scanned
                else { throw ExtensionPeerError.rejected("Review a current scan before cleaning.") }
                model.clean(categoryID: action.value)
            default: throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(
                CleanerUIReply(
                    model: model, known: action.known,
                    knownSelection: mirrored ? model.selectionRevision : action.knownSelection))
        }
        throw ExtensionPeerError.invalidRequest
    }
}
