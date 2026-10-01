import Foundation

public struct SEOAuditLaunch: Sendable {
    public let request: SEOAuditTaskRequest
    public let snapshot: AgentTaskSnapshot?
    public let project: SEOAuditProject?

    public init(
        request: SEOAuditTaskRequest, snapshot: AgentTaskSnapshot? = nil,
        project: SEOAuditProject? = nil
    ) {
        self.request = request
        self.snapshot = snapshot
        self.project = project
    }
}

public struct SEOAuditController: Sendable {
    public var projects: SEOAuditProjectClient
    public var submitTask: @Sendable (AgentTaskSubmission) async throws -> AgentTaskSnapshot
    public var runTask: @Sendable (AgentTaskSubmission) async throws -> Data
    public var cancelTask: @Sendable (UUID) async throws -> AgentTaskSnapshot

    public init(
        projects: SEOAuditProjectClient = SEOAuditProjectClient(),
        submitTask: @escaping @Sendable (AgentTaskSubmission) async throws -> AgentTaskSnapshot = {
            try await AgentTaskClient().submit($0)
        },
        runTask: @escaping @Sendable (AgentTaskSubmission) async throws -> Data = {
            try await AgentTaskClient().run($0)
        },
        cancelTask: @escaping @Sendable (UUID) async throws -> AgentTaskSnapshot = {
            try await AgentTaskClient().cancel($0)
        }
    ) {
        self.projects = projects
        self.submitTask = submitTask
        self.runTask = runTask
        self.cancelTask = cancelTask
    }

    public func list() async throws -> [SEOAuditProjectSummary] {
        try await projects.projects()
    }

    public func show(_ id: UUID) async throws -> SEOAuditProject {
        try await load(id)
    }

    public func create(url: String, name: String?) async throws -> SEOAuditProject {
        try await projects.create(SEOAuditSelection.makeProject(url: url, name: name))
    }

    public func rename(_ id: UUID, name: String) async throws -> SEOAuditProject {
        try await projects.rename(id, name: name)
    }

    public func delete(_ id: UUID) async throws {
        try await projects.delete(id)
    }

    public func draft(_ id: UUID) async throws -> SEOAuditDraft {
        _ = try await load(id)
        return try await projects.draft(id)
    }

    public func discover(_ id: UUID) async throws -> SEOAuditDraft {
        let project = try await load(id)
        guard let url = SEOAuditURLInput.normalize(project.baseURL) else {
            throw SEOAuditInputError("This project does not have a valid site URL.")
        }
        let taskID = UUID()
        var draft = try await projects.draft(id)
        draft.activeTaskIDs.append(taskID)
        _ = try await projects.setDraft(id, draft)
        do {
            let data = try await runTask(
                AgentTaskSubmission(
                    id: taskID, operation: SEOAuditTaskOperation.discover,
                    title: "Discover site pages", payload: try AgentPayload.encode(url)))
            let urls = try AgentPayload.decode([URL].self, from: data)
            draft = try await projects.draft(id)
            let merged = SEOAuditSelection.mergeDiscovery(
                discovered: draft.discoveredPageURLs, selected: Set(draft.selectedPageURLs),
                found: urls.map(\.absoluteString))
            draft.discoveredPageURLs = merged.discovered
            draft.selectedPageURLs = merged.selected
            draft.activeTaskIDs.removeAll { $0 == taskID }
            return try await projects.setDraft(id, draft)
        } catch {
            var failed = (try? await projects.draft(id)) ?? draft
            failed.activeTaskIDs.removeAll { $0 == taskID }
            _ = try? await projects.setDraft(id, failed)
            throw error
        }
    }

    public func choose(_ id: UUID, edit: SEOAuditPageEdit) async throws -> SEOAuditDraft {
        _ = try await load(id)
        var draft = try await projects.draft(id)
        draft.selectedPageURLs = try SEOAuditSelection.choose(
            discovered: draft.discoveredPageURLs, selected: draft.selectedPageURLs, edit: edit)
        return try await projects.setDraft(id, draft)
    }

    public func setLighthouse(_ id: UUID, enabled: Bool) async throws -> SEOAuditDraft {
        _ = try await load(id)
        var draft = try await projects.draft(id)
        draft.includeLighthouse = enabled
        return try await projects.setDraft(id, draft)
    }

    public func start(_ id: UUID, lighthouse: Bool?, wait: Bool) async throws -> SEOAuditLaunch {
        _ = try await load(id)
        let draft = try await projects.draft(id)
        let include = lighthouse ?? draft.includeLighthouse
        let urls = SEOAuditSelection.auditURLs(
            discovered: draft.discoveredPageURLs, selected: Set(draft.selectedPageURLs))
        guard !urls.isEmpty else {
            throw SEOAuditInputError("Select at least one page to audit.")
        }
        let request = SEOAuditTaskRequest(
            projectID: id, runID: UUID(), urls: urls, lighthouse: include)
        var marked = draft
        marked.activeTaskIDs.append(request.runID)
        _ = try await projects.setDraft(id, marked)
        let submission = AgentTaskSubmission(
            id: request.runID, operation: SEOAuditTaskOperation.audit,
            title: "Audit site", payload: try AgentPayload.encode(request))
        do {
            if wait {
                let data = try await runTask(submission)
                var finished = try await projects.draft(id)
                finished.activeTaskIDs.removeAll { $0 == request.runID }
                _ = try await projects.setDraft(id, finished)
                let project = try AgentPayload.decode(SEOAuditProject.self, from: data)
                return SEOAuditLaunch(request: request, project: project)
            }
            let snapshot = try await submitTask(submission)
            return SEOAuditLaunch(request: request, snapshot: snapshot)
        } catch {
            var failed = (try? await projects.draft(id)) ?? marked
            failed.activeTaskIDs.removeAll { $0 == request.runID }
            _ = try? await projects.setDraft(id, failed)
            throw error
        }
    }

    public func stop(_ id: UUID) async throws -> [UUID] {
        let project = try await load(id)
        var draft = try await projects.draft(id)
        var ids = Set(draft.activeTaskIDs)
        for run in project.runs where run.state == .running { ids.insert(run.id) }
        guard !ids.isEmpty else {
            throw SEOAuditInputError("No audit is running for this project.")
        }
        var cancelled: [UUID] = []
        var lastError: Error?
        for taskID in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                _ = try await cancelTask(taskID)
                cancelled.append(taskID)
            } catch {
                lastError = error
            }
        }
        draft.activeTaskIDs.removeAll { ids.contains($0) }
        _ = try await projects.setDraft(id, draft)
        if cancelled.isEmpty, let lastError { throw lastError }
        return cancelled
    }

    public func run(_ id: UUID, runID: UUID?, offset: Int) async throws -> SEOAuditRun {
        let project = try await load(id)
        guard let run = SEOAuditSelection.run(in: project, id: runID, offset: offset) else {
            throw SEOAuditInputError("That audit run is not in this project.")
        }
        return run
    }

    private func load(_ id: UUID) async throws -> SEOAuditProject {
        do { return try await projects.project(id) } catch let error as AgentError {
            throw error
        } catch {
            if Self.isMissingFile(error) {
                throw SEOAuditInputError("No site audit project \(id.uuidString).")
            }
            throw error
        }
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain
            && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError)
    }
}
