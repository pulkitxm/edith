import EdithExtensionSupport
import Foundation

@MainActor
enum CleanerCommands {
    static func execute(_ command: String, payload: Data, model: CleanerModel) async throws -> Data
    {
        switch command {
        case "cleaner.status": return try status(model)
        case "cleaner.scan":
            guard !model.scanning else {
                throw ExtensionPeerError.rejected("Cleaner already has an operation in progress.")
            }
            try Task.checkCancellation()
            model.scan()
            let work = model.commandWork
            let cancel = model.commandCancellation()
            return try await withTaskCancellationHandler {
                await work?.value
                try Task.checkCancellation()
                return try preview(model)
            } onCancel: {
                cancel()
            }
        case "cleaner.preview": return try preview(model)
        case "cleaner.clean":
            guard let input = try? JSONDecoder().decode(CleanerCleanRequest.self, from: payload)
            else { throw ExtensionPeerError.invalidRequest }
            guard input.confirmed, input.previewToken == model.previewToken,
                !model.scanning, model.scanned, model.selectedItemCount > 0,
                (input.categoryID == nil || model.categories.contains { $0.id == input.categoryID })
            else {
                throw ExtensionPeerError.rejected(
                    "Confirm a current Cleaner preview before moving items to the Trash.")
            }
            try Task.checkCancellation()
            model.clean(categoryID: input.categoryID)
            let work = model.commandWork
            let cancel = model.commandCancellation()
            return try await withTaskCancellationHandler {
                await work?.value
                try Task.checkCancellation()
                return try status(model)
            } onCancel: {
                cancel()
            }
        default: throw ExtensionPeerError.rejected("Cleaner does not support this command.")
        }
    }

    private static func status(_ model: CleanerModel) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "working": model.scanning, "scanned": model.scanned,
            "reclaimableBytes": model.reclaimableTotal, "selectedBytes": model.selectedTotal,
            "selectedItems": model.selectedItemCount, "lastReclaimedBytes": model.lastReclaimed,
        ])
    }

    private static func preview(_ model: CleanerModel) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "previewToken": model.previewToken.uuidString, "working": model.scanning,
            "categories": model.categories.map { category in
                [
                    "id": category.id, "name": category.name, "bytes": category.sizeBytes,
                    "items": category.items.map {
                        [
                            "id": $0.id, "name": $0.name, "path": $0.path.path,
                            "bytes": $0.sizeBytes, "selected": $0.selected,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ])
    }
}

private struct CleanerCleanRequest: Decodable {
    let confirmed: Bool
    let previewToken: UUID
    let categoryID: String?
}
