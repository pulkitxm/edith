import AppKit
import CryptoKit
import EdithExtensionSupport
import Foundation

struct SEOAuditUITransfer: Codable {
    let kind: String; let id: UUID; let byteCount: Int; let sha256: String
}
struct SEOAuditUIChunk: Codable { let id: UUID; let offset: Int }

struct SEOAuditUIRequest: Codable {
    let action: String
    var id: UUID? = nil
    var project: SEOAuditProject? = nil
    var name: String? = nil
    var draft: SEOAuditDraft? = nil
    var edit: SEOAuditPageEdit? = nil
    var enabled: Bool? = nil
    var runID: UUID? = nil
    var url: URL? = nil
    var offset: Int? = nil
}
struct SEOAuditUIState: Codable {
    let projects: [SEOAuditProject]
    let drafts: [UUID: SEOAuditDraft]
    let activities: [UUID: SEOAuditActivity]
}
struct SEOAuditUIJob: Codable {
    let id: UUID
    let projectID: UUID
    let kind: SEOAuditJobKind
    let state: SEOAuditJobState
    let request: SEOAuditTaskRequest?
}
struct SEOAuditUIResult: Codable {
    let done: Bool
    var draft: SEOAuditDraft? = nil
    var project: SEOAuditProject? = nil
    var error: String? = nil
}

@MainActor struct SEOAuditUIBridge {
    let invoke: (String, Data) async throws -> Data
    init(client: ExtensionEngineClient) { invoke = { try await client.invoke($0, payload: $1) } }
    init(invoke: @escaping (String, Data) async throws -> Data) { self.invoke = invoke }
    func call<T: Decodable>(
        _ action: String, id: UUID? = nil, project: SEOAuditProject? = nil,
        name: String? = nil, draft: SEOAuditDraft? = nil, edit: SEOAuditPageEdit? = nil,
        enabled: Bool? = nil, runID: UUID? = nil, url: URL? = nil, offset: Int? = nil,
        as: T.Type = T.self
    ) async throws -> T {
        let request = SEOAuditUIRequest(
            action: action, id: id, project: project, name: name,
            draft: draft, edit: edit, enabled: enabled, runID: runID, url: url, offset: offset)
        var data = try await invoke("seoAudit.ui.action", JSONEncoder().encode(request))
        if let transfer = try? JSONDecoder().decode(SEOAuditUITransfer.self, from: data),
            transfer.kind == "seo-ui-transfer"
        {
            defer {
                Task {
                    _ = try? await invoke(
                        "seoAudit.ui.release",
                        JSONEncoder().encode(SEOAuditUIChunk(id: transfer.id, offset: 0)))
                }
            }
            guard (0...67_108_864).contains(transfer.byteCount) else {
                throw ExtensionPeerError.invalidRequest
            }
            data = Data()
            while data.count < transfer.byteCount {
                try Task.checkCancellation()
                let chunk = try JSONDecoder().decode(
                    Data.self,
                    from: await invoke(
                        "seoAudit.ui.chunk",
                        JSONEncoder().encode(SEOAuditUIChunk(id: transfer.id, offset: data.count))))
                guard !chunk.isEmpty, data.count + chunk.count <= transfer.byteCount else {
                    throw ExtensionPeerError.invalidRequest
                }
                data.append(chunk)
            }
            guard Self.hash(data) == transfer.sha256 else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func state() async throws -> SEOAuditUIState { try await call("state") }
    func job(_ launch: SEOAuditUIJob) -> SEOAuditJob {
        let task = Task<SEOAuditJobResult, Error> {
            try await withTaskCancellationHandler {
                while !Task.isCancelled {
                    let result: SEOAuditUIResult = try await call("job", id: launch.id)
                    if let error = result.error { throw SEOAuditInputError(error) }
                    if let draft = result.draft { return .draft(draft) }
                    if let project = result.project { return .project(project) }
                    guard !result.done else { throw ExtensionPeerError.invalidRequest }
                    try await Task.sleep(for: .milliseconds(500))
                }
                throw CancellationError()
            } onCancel: {
                Task { @MainActor in let _: Bool? = try? await call("cancel", id: launch.id) }
            }
        }
        return .init(id: launch.id, projectID: launch.projectID, kind: launch.kind, task: task)
    }
}

@MainActor final class SEOAuditUIEngine {
    private let service: SEOAuditService
    private var pending: [UUID: SEOAuditJob] = [:]
    private var results: [UUID: Data] = [:]
    private var expiry: [UUID: Task<Void, Never>] = [:]
    init(service: SEOAuditService) { self.service = service }
    func shutdown() {
        pending.removeAll(); results.removeAll(); for task in expiry.values { task.cancel() };
        expiry.removeAll()
    }
    private func transport(_ data: Data) throws -> Data {
        guard data.count <= 67_108_864 else { throw ExtensionPeerError.invalidRequest }
        if data.count <= 3_000_000 { return data }
        guard results.count < 4 else { throw ExtensionPeerError.unavailable }
        let id = UUID(); results[id] = data
        expiry[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.results[id] = nil; self?.expiry[id] = nil
        }
        return try JSONEncoder().encode(
            SEOAuditUITransfer(
                kind: "seo-ui-transfer", id: id, byteCount: data.count,
                sha256: SEOAuditUIBridge.hash(data)))
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        if ["seoAudit.ui.chunk", "seoAudit.ui.release"].contains(command) {
            guard !service.isStopped, payload.count <= 1024 else {
                throw ExtensionPeerError.invalidRequest
            }
            let request = try JSONDecoder().decode(SEOAuditUIChunk.self, from: payload)
            guard let data = results[request.id], request.offset >= 0, request.offset <= data.count
            else { throw ExtensionPeerError.invalidRequest }
            if command == "seoAudit.ui.release" {
                results[request.id] = nil; expiry.removeValue(forKey: request.id)?.cancel();
                return Data("{}".utf8)
            }
            return try JSONEncoder().encode(
                data.subdata(in: request.offset..<min(data.count, request.offset + 65_536)))
        }
        guard command == "seoAudit.ui.action", !service.isStopped, payload.count <= 524_288 else {
            throw ExtensionPeerError.unavailable
        }
        let request = try JSONDecoder().decode(SEOAuditUIRequest.self, from: payload)
        func id() throws -> UUID {
            guard let id = request.id else { throw ExtensionPeerError.invalidRequest }; return id
        }
        func encode<T: Encodable>(_ value: T) throws -> Data {
            try transport(JSONEncoder().encode(value))
        }
        switch request.action {
        case "image":
            guard let url = request.url else { throw ExtensionPeerError.invalidRequest }
            var allowed = false
            for summary in try await service.list() {
                let project = try await service.project(summary.id)
                var images = [project.imageURL, project.imageSnapshotURL].compactMap { $0 }
                for run in project.runs {
                    for page in run.pages {
                        images += [
                            page.metadata.openGraphImageURL,
                            page.metadata.openGraphImageSnapshotURL, page.metadata.twitterImageURL,
                            page.metadata.twitterImageSnapshotURL,
                        ].compactMap { $0 }
                    }
                }
                if images.contains(url.absoluteString) { allowed = true; break }
            }
            guard allowed else { throw ExtensionPeerError.invalidRequest }
            let image = await SEOSnapshotCache.shared.image(for: url)
            let bytes = image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .jpeg, properties: [.compressionFactor: 0.75])
            guard bytes?.count ?? 0 <= 2_097_152 else { throw ExtensionPeerError.invalidRequest }
            return try encode(bytes)
        case "available": return try encode(await service.lighthouseAvailable())
        case "list": return try encode(await service.list())
        case "project": return try encode(await service.project(id()))
        case "draft": return try encode(await service.draft(id()))
        case "state":
            let summaries = try await service.list()
            var projects: [SEOAuditProject] = []
            var drafts: [UUID: SEOAuditDraft] = [:]
            for summary in summaries {
                projects.append(try await service.project(summary.id))
                drafts[summary.id] = try await service.draft(summary.id)
            }
            return try encode(
                SEOAuditUIState(projects: projects, drafts: drafts, activities: service.activities))
        case "create":
            guard let project = request.project else { throw ExtensionPeerError.invalidRequest }
            return try encode(await service.create(project))
        case "rename":
            guard let name = request.name, !name.isEmpty, name.utf8.count <= 256 else {
                throw ExtensionPeerError.invalidRequest
            }
            return try encode(await service.rename(id(), name: name))
        case "delete": try await service.delete(id()); return try encode(true)
        case "setDraft":
            guard let draft = request.draft else { throw ExtensionPeerError.invalidRequest }
            return try encode(await service.setDraft(id(), draft))
        case "choose":
            guard let edit = request.edit else { throw ExtensionPeerError.invalidRequest }
            return try encode(await service.choose(id(), edit: edit))
        case "setLighthouse":
            guard let enabled = request.enabled else { throw ExtensionPeerError.invalidRequest }
            return try encode(await service.setLighthouse(id(), enabled: enabled))
        case "discover":
            guard pending.count < 16 else { throw ExtensionPeerError.unavailable }
            let job = try await service.discover(id()); pending[job.id] = job
            return try encode(
                SEOAuditUIJob(
                    id: job.id, projectID: job.projectID, kind: job.kind, state: .queued,
                    request: nil))
        case "start", "lighthouse":
            guard pending.count < 16 else { throw ExtensionPeerError.unavailable }
            let launch: SEOAuditLaunch
            if request.action == "start" {
                launch = try await service.start(id(), lighthouse: request.enabled)
            } else {
                guard let runID = request.runID, let url = request.url else {
                    throw ExtensionPeerError.invalidRequest
                }
                launch = try await service.lighthouse(id(), runID: runID, url: url)
            }
            pending[launch.job.id] = launch.job
            return try encode(
                SEOAuditUIJob(
                    id: launch.job.id, projectID: launch.job.projectID, kind: launch.job.kind,
                    state: launch.state, request: launch.request))
        case "job":
            let id = try id()
            guard let job = pending[id] else { throw ExtensionPeerError.invalidRequest }
            if service.job(id) != nil { return try encode(SEOAuditUIResult(done: false)) }
            pending[id] = nil
            do {
                switch try await job.value(cancellingOnCancel: false) {
                case .draft(let draft):
                    return try encode(SEOAuditUIResult(done: true, draft: draft))
                case .project(let project):
                    return try encode(SEOAuditUIResult(done: true, project: project))
                }
            } catch {
                return try encode(SEOAuditUIResult(done: true, error: error.localizedDescription))
            }
        case "stop": return try encode(await service.stop(id()))
        case "cancel":
            let taskID = try id(); let result = service.cancel(taskID); pending[taskID] = nil;
            return try encode(result)
        case "run":
            guard (0...10_000).contains(request.offset ?? 0) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try encode(
                await service.run(id(), runID: request.runID, offset: request.offset ?? 0))
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
