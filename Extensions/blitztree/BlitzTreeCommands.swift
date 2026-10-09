import EdithExtensionSupport
import Foundation

@MainActor
enum BlitzTreeCommands {
    static func execute(_ command: String, payload: Data, model: BlitzTreeModel) async throws
        -> Data
    {
        guard !model.stopped else { throw ExtensionPeerError.unavailable }
        switch command {
        case "blitztree.status", "blitztree.preview": return try preview(model)
        case "blitztree.cancel":
            model.cancel()
            await model.finishWork()
            return try preview(model)
        case "blitztree.scan":
            guard let request = try? JSONDecoder().decode(ScanRequest.self, from: payload),
                !model.removing,
                request.path.hasPrefix("/"), !request.path.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            return try await perform(model) { model.scan(request.path) }
        case "blitztree.trash":
            guard let request = try? JSONDecoder().decode(TrashRequest.self, from: payload),
                request.confirmed, request.previewToken == model.previewToken,
                !model.scanning, !model.removing, let report = model.report,
                let entry = model.entries(in: report).first(where: { $0.path == request.path })
            else {
                throw ExtensionPeerError.rejected(
                    "Confirm a current scan preview before moving an item to Trash.")
            }
            return try await perform(model) { model.trash(entry) }
        default: throw ExtensionPeerError.rejected("BlitzTree does not support this command.")
        }
    }

    private static func perform(_ model: BlitzTreeModel, _ action: () -> Void) async throws -> Data
    {
        try await withTaskCancellationHandler {
            action()
            await model.finishWork()
            try Task.checkCancellation()
            if let error = model.error { throw ExtensionPeerError.rejected(error) }
            return try preview(model)
        } onCancel: {
            Task { @MainActor in model.cancel() }
        }
    }

    private static func preview(_ model: BlitzTreeModel) throws -> Data {
        try JSONEncoder().encode(
            Preview(
                previewToken: model.previewToken, working: model.scanning || model.removing,
                report: model.report))
    }

    private struct ScanRequest: Decodable { let path: String }
    private struct TrashRequest: Decodable {
        let confirmed: Bool; let previewToken: UUID; let path: String
    }
    private struct Preview: Encodable {
        let previewToken: UUID; let working: Bool; let report: BlitzTreeReport?
    }
}
