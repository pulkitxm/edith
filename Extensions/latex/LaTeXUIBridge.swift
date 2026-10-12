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
    var pdfPreview: Data?
    let pdfByteCount: Int
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
        pdfPreview = nil
        if let project = model.selected, project.location == .disk,
            FileManager.default.fileExists(atPath: project.pdfURL.path)
        {
            let attributes = try FileManager.default.attributesOfItem(atPath: project.pdfURL.path)
            pdfByteCount = attributes[.size] as? Int ?? 0
        } else {
            pdfByteCount = model.pdfPreview?.count ?? 0
        }
        guard pdfByteCount <= 67_108_864 else {
            throw ExtensionPeerError.rejected("The PDF exceeds the 64 MiB transfer limit.")
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

struct LaTeXPDFChunkRequest: Codable { let projectID: UUID; let generation: UUID; let offset: Int }

@MainActor final class LaTeXUIBridge {
    private var cachedPDF: (UUID, UUID, Data)?
    let invoke: (String, Data) async throws -> Data

    init(client: ExtensionEngineClient) {
        invoke = { try await client.invoke($0, payload: $1, timeout: 30) }
    }

    init(invoke: @escaping (String, Data) async throws -> Data) { self.invoke = invoke }

    func snapshot() async throws -> LaTeXUISnapshot {
        let data = try await invoke("latex.ui.snapshot", Data("{}".utf8))
        return try await withPDF(JSONDecoder().decode(LaTeXUISnapshot.self, from: data))
    }

    func perform(_ request: LaTeXUIAction) async throws -> LaTeXUISnapshot {
        let data = try await invoke("latex.ui.action", JSONEncoder().encode(request))
        return try await withPDF(JSONDecoder().decode(LaTeXUISnapshot.self, from: data))
    }

    private func withPDF(_ value: LaTeXUISnapshot) async throws -> LaTeXUISnapshot {
        guard let id = value.selectedID, value.pdfByteCount > 0 else {
            cachedPDF = nil; return value
        }
        var bytes = Data()
        if let cachedPDF, cachedPDF.0 == id, cachedPDF.1 == value.buildGeneration,
            cachedPDF.2.count == value.pdfByteCount
        {
            bytes = cachedPDF.2
        } else {
            while bytes.count < value.pdfByteCount {
                try Task.checkCancellation()
                let request = LaTeXPDFChunkRequest(
                    projectID: id, generation: value.buildGeneration, offset: bytes.count)
                let chunk = try JSONDecoder().decode(
                    Data.self,
                    from: await invoke("latex.ui.pdfChunk", JSONEncoder().encode(request)))
                guard !chunk.isEmpty, bytes.count + chunk.count <= value.pdfByteCount else {
                    throw ExtensionPeerError.invalidRequest
                }
                bytes.append(chunk)
            }
            cachedPDF = (id, value.buildGeneration, bytes)
        }
        var result = value; result.pdfPreview = bytes; return result
    }

    static func execute(_ command: String, payload: Data, model: LaTeXModel) async throws -> Data {
        guard !model.isStopped, payload.count <= 1_048_576 else {
            throw ExtensionPeerError.unavailable
        }
        await model.start()
        try Task.checkCancellation()
        switch command {
        case "latex.ui.pdfChunk":
            let request = try JSONDecoder().decode(LaTeXPDFChunkRequest.self, from: payload)
            guard let project = model.selected, project.id == request.projectID,
                model.buildGeneration == request.generation, request.offset >= 0
            else { throw ExtensionPeerError.invalidRequest }
            let bytes: Data
            if project.location == .disk {
                let file = try FileHandle(forReadingFrom: project.pdfURL);
                defer { try? file.close() }
                let length = try file.seekToEnd()
                guard length <= 67_108_864, request.offset < length else {
                    throw ExtensionPeerError.invalidRequest
                }
                try file.seek(toOffset: UInt64(request.offset));
                bytes = try file.read(upToCount: 65_536) ?? Data()
            } else {
                guard let data = model.pdfPreview, request.offset < data.count else {
                    throw ExtensionPeerError.invalidRequest
                }
                bytes = data.subdata(in: request.offset..<min(data.count, request.offset + 65_536))
            }
            return try JSONEncoder().encode(bytes)
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
                    case "openPDF": try model.deliverPDF(save: false)
                    case "savePDF": try model.deliverPDF(save: true)
                    case "buildURL": try model.deliverBuildURL()
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
