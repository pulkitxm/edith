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
}
struct CleanerUIAction: Codable {
    let operation: String; let value: String?; let item: String?; let previewToken: UUID
}
@MainActor enum CleanerUICommands {
    static func execute(_ command: String, payload: Data, model: CleanerModel) async throws -> Data
    {
        guard !model.stopped else { throw ExtensionPeerError.unavailable }
        if command == "cleaner.ui.snapshot" {
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
        } else if command == "cleaner.ui.action" {
            let action = try JSONDecoder().decode(CleanerUIAction.self, from: payload)
            if ["all", "category", "item"].contains(action.operation) {
                guard action.previewToken == model.previewToken, !model.scanning, model.scanned
                else {
                    throw ExtensionPeerError.rejected(
                        "Review a current scan before changing its selection.")
                }
            }
            switch action.operation {
            case "scan": model.scan()
            case "cancel": model.cancelScan()
            case "drives": model.loadDriveOptions()
            case "all": model.toggleAll()
            case "category":
                guard let id = action.value, model.categories.contains(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                model.toggleCategory(id)
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
            case "clean":
                guard action.previewToken == model.previewToken, !model.scanning, model.scanned
                else { throw ExtensionPeerError.rejected("Review a current scan before cleaning.") }
                model.clean(categoryID: action.value)
            default: throw ExtensionPeerError.invalidRequest
            }
        } else {
            throw ExtensionPeerError.invalidRequest
        }
        return try JSONEncoder().encode(model.uiSnapshot())
    }
}
