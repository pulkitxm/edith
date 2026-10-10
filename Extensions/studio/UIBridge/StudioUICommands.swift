import EdithExtensionSupport
import EdithStudio
import Foundation

@MainActor enum StudioUICommands {
    private static let fields: [String: Set<String>] = [
        "studio.ui.state": [],
        "studio.ui.facts": ["path"],
        "studio.ui.clearMissing": [],
    ]

    static func execute(_ operation: String, payload: Data, model: StudioModel) async throws -> Data
    {
        try Task.checkCancellation()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        guard let allowed = fields[operation], !payload.isEmpty,
            payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw ExtensionPeerError.invalidRequest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch operation {
        case "studio.ui.state":
            let files = try StudioMediaLibrary.list(defaults: model.defaults)
            let value = try await BlockingWork.perform {
                StudioUIState(
                    files: files.filter { FileManager.default.fileExists(atPath: $0.url.path) },
                    projects: VideoProject.listProjects().map(StudioUIState.Project.init),
                    recent: StudioLibraryStore.loadRecent(), workflows: StudioWorkflowStore.load(),
                    environment: StudioUIState.Environment(StudioEngineLocator.detect()))
            }
            try Task.checkCancellation()
            return try encoder.encode(value)
        case "studio.ui.facts":
            guard let path = object["path"] as? String else {
                throw ExtensionPeerError.invalidRequest
            }
            let url = try StudioCommands.localPath(path)
            let facts = await StudioInspector.facts(for: url)
            try Task.checkCancellation()
            return try encoder.encode(StudioUIFileFacts(facts))
        case "studio.ui.clearMissing":
            let items = try StudioMediaLibrary.list(defaults: model.defaults)
            let missing = Set(
                items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.url))
            let remaining = try StudioMediaLibrary.remove(missing, defaults: model.defaults)
            model.refreshLibrary()
            return try encoder.encode(remaining)
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
