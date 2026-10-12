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
    private let cleanup = SEOAuditBridgeTasks()
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
                cleanup.start {
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
    var retirementError: String? { cleanup.lastError }
    func drain() async { await cleanup.wait() }

    func state() async throws -> SEOAuditUIState { try await call("state") }
    func job(_ launch: SEOAuditUIJob) -> SEOAuditJob {
        let task = Task<SEOAuditJobResult, Error> {
            var terminalObserved = false
            do {
                while true {
                    try Task.checkCancellation()
                    let result: SEOAuditUIResult = try await call("job", id: launch.id)
                    if result.done {
                        terminalObserved = true
                        cleanup.start { await release(launch.id) }
                    }
                    if let error = result.error { throw SEOAuditInputError(error) }
                    if let draft = result.draft { return .draft(draft) }
                    if let project = result.project { return .project(project) }
                    guard !result.done else { throw ExtensionPeerError.invalidRequest }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                if Task.isCancelled && !terminalObserved {
                    let cancellation = cleanup.start {
                        while true {
                            do {
                                let joined: Bool = try await call("cancel", id: launch.id)
                                if joined {
                                    await release(launch.id)
                                    return
                                }
                                let result: SEOAuditUIResult = try await call("job", id: launch.id)
                                if result.done {
                                    await release(launch.id)
                                    return
                                }
                            } catch { cleanup.record(error) }
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    await cancellation.value
                }
                throw error
            }
        }
        return .init(id: launch.id, projectID: launch.projectID, kind: launch.kind, task: task)
    }

    private func release(_ id: UUID) async {
        while true {
            do {
                let released: Bool = try await call("releaseJob", id: id)
                if released { return }
                cleanup.record(ExtensionPeerError.invalidRequest)
            } catch { cleanup.record(error) }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

@MainActor final class SEOAuditUIJobs {
    private(set) var pending: [UUID: SEOAuditJob] = [:]
    var count: Int { pending.count }

    func retain(_ job: SEOAuditJob) { pending[job.id] = job }

    func cancel(_ id: UUID) async -> Bool {
        guard let job = pending[id] else { return false }
        job.task.cancel()
        _ = await job.task.result
        return true
    }

    func result(_ id: UUID, running: Bool) async throws -> SEOAuditUIResult {
        guard let job = pending[id] else { throw ExtensionPeerError.invalidRequest }
        if running { return SEOAuditUIResult(done: false) }
        do {
            switch try await job.value(cancellingOnCancel: false) {
            case .draft(let draft): return SEOAuditUIResult(done: true, draft: draft)
            case .project(let project): return SEOAuditUIResult(done: true, project: project)
            }
        } catch {
            return SEOAuditUIResult(done: true, error: error.localizedDescription)
        }
    }

    func release(_ id: UUID) async -> Bool {
        guard let job = pending[id] else { return true }
        _ = await job.task.result
        pending[id] = nil
        return true
    }

    func closeAndWait() async {
        let jobs = Array(pending.values)
        for job in jobs { job.task.cancel() }
        for job in jobs { _ = await job.task.result }
        pending.removeAll()
    }
}

@MainActor final class SEOAuditUIEngine {
    private let service: SEOAuditService
    private let jobs = SEOAuditUIJobs()
    private var results: [UUID: Data] = [:]
    private var expiry: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    init(service: SEOAuditService) { self.service = service }
    func shutdown() {
        stopped = true
        for job in jobs.pending.values { job.task.cancel() }
        for task in expiry.values { task.cancel() }
    }

    func suspendAndWait() async {
        shutdown()
        let jobs = Array(jobs.pending.values), timers = Array(expiry.values)
        for job in jobs { _ = await job.task.result }
        for task in timers { await task.value }
    }

    func shutdownAndWait() async {
        await suspendAndWait()
        await jobs.closeAndWait()
        results.removeAll()
    }
    private func transport(_ data: Data) throws -> Data {
        guard data.count <= 67_108_864 else { throw ExtensionPeerError.invalidRequest }
        if data.count <= 3_000_000 { return data }
        guard results.count < 4 else { throw ExtensionPeerError.unavailable }
        let id = UUID(); results[id] = data
        expiry[id] = Task { [self] in
            defer { expiry[id] = nil }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard !stopped else { return }
            results[id] = nil
        }
        return try JSONEncoder().encode(
            SEOAuditUITransfer(
                kind: "seo-ui-transfer", id: id, byteCount: data.count,
                sha256: SEOAuditUIBridge.hash(data)))
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
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
            guard jobs.count < 16 else { throw ExtensionPeerError.unavailable }
            let job = try await service.discover(id()); jobs.retain(job)
            return try encode(
                SEOAuditUIJob(
                    id: job.id, projectID: job.projectID, kind: job.kind, state: .queued,
                    request: nil))
        case "start", "lighthouse":
            guard jobs.count < 16 else { throw ExtensionPeerError.unavailable }
            let launch: SEOAuditLaunch
            if request.action == "start" {
                launch = try await service.start(id(), lighthouse: request.enabled)
            } else {
                guard let runID = request.runID, let url = request.url else {
                    throw ExtensionPeerError.invalidRequest
                }
                launch = try await service.lighthouse(id(), runID: runID, url: url)
            }
            jobs.retain(launch.job)
            return try encode(
                SEOAuditUIJob(
                    id: launch.job.id, projectID: launch.job.projectID, kind: launch.job.kind,
                    state: launch.state, request: launch.request))
        case "job":
            let taskID = try id()
            return try encode(await jobs.result(taskID, running: service.job(taskID) != nil))
        case "releaseJob": return try encode(await jobs.release(id()))
        case "stop": return try encode(await service.stop(id()))
        case "cancel": return try encode(await jobs.cancel(id()))
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

@MainActor private final class SEOAuditBridgeTasks {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var lastError: String?

    func record(_ error: Error) { lastError = error.localizedDescription }

    @discardableResult func start(_ operation: @escaping @MainActor () async -> Void) -> Task<
        Void, Never
    > {
        let id = UUID()
        let task = Task { [self] in
            defer { tasks[id] = nil }
            await operation()
        }
        tasks[id] = task
        return task
    }

    func wait() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }
}
