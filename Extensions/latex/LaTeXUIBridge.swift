import AppKit
import EdithExtensionSupport
import Foundation

struct LaTeXToolsSnapshot: Codable {
    let status: [String: String]
    let installed: Set<String>
    let busy: Set<String>
}

struct LaTeXUISnapshot: Codable {
    let projects: [LaTeXProject]
    let selectedID: UUID?
    let source: String
    let original: LaTeXSource?
    let review: LaTeXReview?
    let pdfPreview: Data?
    let log: String
    let buildGeneration: UUID
    let editorRequest: UInt64
    let busy: Bool
    let buildingPDF: Bool
    let hasRepositoryBuild: Bool
    let buildURL: URL?
    let message: String?
    let tools: LaTeXToolsSnapshot

    @MainActor init(model: LaTeXModel) throws {
        projects = model.projects; selectedID = model.selectedID
        source = model.source; original = model.original; review = model.review
        if let project = model.selected, project.location == .disk,
            FileManager.default.fileExists(atPath: project.pdfURL.path)
        {
            let attributes = try FileManager.default.attributesOfItem(atPath: project.pdfURL.path)
            guard (attributes[.size] as? Int ?? 0) <= 2_097_152 else {
                throw ExtensionPeerError.rejected("The PDF exceeds the embedded preview limit.")
            }
            pdfPreview = try Data(contentsOf: project.pdfURL)
        } else {
            pdfPreview = model.pdfPreview
        }
        editorRequest = model.editorRequest
        log = model.log; buildGeneration = model.buildGeneration
        busy = model.busy; buildingPDF = model.buildingPDF
        hasRepositoryBuild = model.hasRepositoryBuild; buildURL = model.buildURL
        message = model.message; tools = model.tools.snapshot
    }
}

struct LaTeXUIAction: Codable {
    let action: String
    var projectID: UUID? = nil
    var project: LaTeXProject? = nil
    var revision: String? = nil
    var text: String? = nil
    var automatically: Bool? = nil
    var tool: String? = nil
}

@MainActor struct LaTeXUIBridge {
    let invoke: (String, Data) async throws -> Data

    init(client: ExtensionEngineClient) {
        invoke = { try await client.invoke($0, payload: $1, timeout: 30) }
    }

    init(invoke: @escaping (String, Data) async throws -> Data) { self.invoke = invoke }

    func snapshot() async throws -> LaTeXUISnapshot {
        let data = try await invoke("latex.ui.snapshot", Data("{}".utf8))
        return try JSONDecoder().decode(LaTeXUISnapshot.self, from: data)
    }

    func perform(_ request: LaTeXUIAction) async throws -> LaTeXUISnapshot {
        let data = try await invoke("latex.ui.action", JSONEncoder().encode(request))
        return try JSONDecoder().decode(LaTeXUISnapshot.self, from: data)
    }

    static func execute(_ command: String, payload: Data, model: LaTeXModel) async throws -> Data {
        guard !model.isStopped, payload.count <= 1_048_576 else {
            throw ExtensionPeerError.unavailable
        }
        await model.start()
        try Task.checkCancellation()
        switch command {
        case "latex.ui.snapshot":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
        case "latex.ui.action":
            let request = try JSONDecoder().decode(LaTeXUIAction.self, from: payload)
            guard request.text?.utf8.count ?? 0 <= 1_048_576 else {
                throw ExtensionPeerError.invalidRequest
            }
            if request.action == "add" {
                guard let project = request.project else { throw ExtensionPeerError.invalidRequest }
                try await model.add(project)
            } else if request.action == "tools.refresh" {
                model.tools.refresh()
            } else if request.action == "tools.install" {
                guard let tool = request.tool, ["tectonic", "gh", "pukbot"].contains(tool) else {
                    throw ExtensionPeerError.invalidRequest
                }
                model.tools.install(tool)
            } else {
                guard let id = request.projectID, model.projects.contains(where: { $0.id == id })
                else { throw ExtensionPeerError.invalidRequest }
                if request.action == "select" {
                    guard !model.dirty, !model.busy else {
                        throw ExtensionPeerError.rejected(
                            "Save or discard the current source first.")
                    }
                    await model.select(id)
                    model.requestEditor()
                } else {
                    guard model.selectedID == id, !model.busy else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    if let text = request.text {
                        guard model.original?.revision == request.revision else {
                            throw ExtensionPeerError.rejected(
                                "The source revision changed. Reload before editing.")
                        }
                        model.source = text
                    }
                    switch request.action {
                    case "draft": break
                    case "reload": await model.reload()
                    case "remove": model.remove()
                    case "discard": model.discard()
                    case "save": model.saveAndCompile()
                    case "submit": model.submit()
                    case "pdf": model.refreshPDF()
                    case "review": model.refreshReview()
                    case "merge": model.merge(automatically: request.automatically ?? false)
                    case "reveal": model.revealSource()
                    default: throw ExtensionPeerError.invalidRequest
                    }
                }
            }
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        return try JSONEncoder().encode(LaTeXUISnapshot(model: model))
    }
}
