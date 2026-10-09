import EdithExtensionSupport
import Foundation

@MainActor final class LaTeXWorker {
    let model: LaTeXModel
    let surface: LaTeXSurface
    private(set) var isStopped = false

    init(model: LaTeXModel? = nil) {
        let model = model ?? LaTeXModel()
        self.model = model; surface = LaTeXSurface(model: model)
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped, !model.isStopped else { throw ExtensionPeerError.unavailable }
        if command.hasPrefix("surface.") {
            return try await surface.execute(command, payload: payload)
        }
        guard payload.count <= 524_288 else { throw ExtensionPeerError.invalidRequest }
        switch command {
        case "latex.projects":
            await model.start()
            try Task.checkCancellation()
            return try JSONEncoder().encode(model.projects)
        case "latex.addProject":
            try await model.add(JSONDecoder().decode(LaTeXProject.self, from: payload))
            return try JSONEncoder().encode(model.projects)
        case "latex.editorStatus":
            return try JSONSerialization.data(withJSONObject: [
                "ready": model.editorControls.ready,
                "dirty": model.dirty, "toolProcesses": model.tools.busy.count,
            ])
        case "latex.document":
            await model.start()
            guard let original = model.original else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                LaTeXDocumentSnapshot(text: model.source, revision: original.revision))
        case "latex.setDraft":
            let request = try JSONDecoder().decode(LaTeXDraftRequest.self, from: payload)
            guard model.selectedID == request.projectID,
                model.original?.revision == request.revision,
                !model.busy
            else { throw ExtensionPeerError.invalidRequest }
            model.source = request.text
            return Data()
        case "latex.loadProject", "latex.openProject":
            let id = try JSONDecoder().decode(UUID.self, from: payload)
            guard model.projects.contains(where: { $0.id == id }), !model.dirty, !model.busy else {
                throw ExtensionPeerError.invalidRequest
            }
            await model.select(id)
            try Task.checkCancellation()
            if command == "latex.openProject" { model.requestEditor() }
            guard let original = model.original, model.selectedID == id else {
                throw ExtensionPeerError.rejected(
                    model.load.errorMessage ?? "The source could not load.")
            }
            return try JSONEncoder().encode(
                LaTeXDocumentSnapshot(text: original.text, revision: original.revision))
        case "latex.removeProject":
            let id = try JSONDecoder().decode(UUID.self, from: payload)
            guard model.projects.contains(where: { $0.id == id }), !model.dirty, !model.busy else {
                throw ExtensionPeerError.invalidRequest
            }
            await model.select(id)
            try Task.checkCancellation()
            model.remove()
            return try JSONEncoder().encode(model.projects)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        await model.shutdown()
    }
}

private struct LaTeXDocumentSnapshot: Codable {
    let text: String
    let revision: String
}

private struct LaTeXDraftRequest: Codable {
    let projectID: UUID
    let revision: String
    let text: String
}
