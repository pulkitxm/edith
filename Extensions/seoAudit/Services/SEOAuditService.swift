import Foundation
import Observation

enum SEOAuditJobState: String, Codable, Sendable {
    case queued
    case running
}

struct SEOAuditActivity: Equatable, Sendable {
    let taskID: UUID
    let kind: SEOAuditJobKind
    var state: SEOAuditJobState
    var stage: SEOAuditStage
    var runID: UUID?
    var completed = 0
    var total = 0

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

enum SEOAuditJobResult: Sendable {
    case draft(SEOAuditDraft)
    case project(SEOAuditProject)
}

struct SEOAuditJob: Sendable {
    let id: UUID
    let projectID: UUID
    let kind: SEOAuditJobKind
    let task: Task<SEOAuditJobResult, Error>

    func value(cancellingOnCancel: Bool) async throws -> SEOAuditJobResult {
        guard cancellingOnCancel else { return try await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct SEOAuditLaunch: Sendable {
    let request: SEOAuditTaskRequest
    let job: SEOAuditJob
    let state: SEOAuditJobState
}

enum SEOAuditEvent: Sendable {
    case project(SEOAuditProject)
    case deleted(UUID)
    case draft(UUID, SEOAuditDraft)
}

actor SEOAuditGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    var waiting: Int { waiters.count }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
@Observable
final class SEOAuditService {
    let workflow: SEOAuditWorkflow
    private(set) var activities: [UUID: SEOAuditActivity] = [:]
    private(set) var isStopped = false
    @ObservationIgnored private var jobs: [UUID: SEOAuditJob] = [:]
    @ObservationIgnored private var listeners: [UUID: (SEOAuditEvent) -> Void] = [:]
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private let gate = SEOAuditGate()

    init(workflow: SEOAuditWorkflow = SEOAuditWorkflow()) {
        self.workflow = workflow
        recovery = Task { try? await workflow.recoverInterruptedRuns() }
    }

    var jobCount: Int { jobs.count }
    var listenerCount: Int { listeners.count }

    func observe(_ listener: @escaping (SEOAuditEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func stopObserving(_ id: UUID?) {
        guard let id else { return }
        listeners[id] = nil
    }

    func activity(for projectID: UUID) -> SEOAuditActivity? { activities[projectID] }

    func job(_ id: UUID) -> SEOAuditJob? { jobs[id] }

    func job(forProject projectID: UUID) -> SEOAuditJob? {
        jobs.values.first { $0.projectID == projectID }
    }

    func activeTaskIDs(_ projectID: UUID) -> [UUID] {
        jobs.values.filter { $0.projectID == projectID }.map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    func lighthouseAvailable() async -> Bool {
        await workflow.lighthouseAuditor.isAvailable()
    }

    func list() async throws -> [SEOAuditProjectSummary] {
        try await ready()
        return try await workflow.projects()
    }

    func project(_ id: UUID) async throws -> SEOAuditProject {
        try await ready()
        return try await workflow.project(id)
    }

    func create(url: String, name: String?) async throws -> SEOAuditProject {
        try await create(SEOAuditSelection.makeProject(url: url, name: name))
    }

    func create(_ project: SEOAuditProject) async throws -> SEOAuditProject {
        try await ready()
        let created = try await workflow.create(project)
        publish(.project(created))
        return created
    }

    func rename(_ id: UUID, name: String) async throws -> SEOAuditProject {
        try await ready()
        try requireIdle(id)
        let project = try await workflow.rename(id, name: name)
        publish(.project(project))
        return project
    }

    func delete(_ id: UUID) async throws {
        try await ready()
        try requireIdle(id)
        try await workflow.delete(id)
        publish(.deleted(id))
    }

    func draft(_ id: UUID) async throws -> SEOAuditDraft {
        try await ready()
        return try await workflow.draft(id)
    }

    func setDraft(_ id: UUID, _ draft: SEOAuditDraft) async throws -> SEOAuditDraft {
        try await ready()
        let saved = try await workflow.setDraft(id, draft)
        publish(.draft(id, saved))
        return saved
    }

    func choose(_ id: UUID, edit: SEOAuditPageEdit) async throws -> SEOAuditDraft {
        try await ready()
        let draft = try await workflow.updateDraft(id) { draft in
            draft.selectedPageURLs = try SEOAuditSelection.choose(
                discovered: draft.discoveredPageURLs, selected: draft.selectedPageURLs,
                edit: edit)
        }
        publish(.draft(id, draft))
        return draft
    }

    func setLighthouse(_ id: UUID, enabled: Bool) async throws -> SEOAuditDraft {
        try await ready()
        let draft = try await workflow.updateDraft(id) { $0.includeLighthouse = enabled }
        publish(.draft(id, draft))
        return draft
    }

    func discover(_ id: UUID) async throws -> SEOAuditJob {
        try await ready()
        let project = try await workflow.project(id)
        guard let url = SEOAuditURLInput.normalize(project.baseURL) else {
            throw SEOAuditInputError("This project does not have a valid site URL.")
        }
        try requireIdle(id)
        let workflow = workflow
        return submit(projectID: id, kind: .discover, stage: .discovering, runID: nil) {
            let urls = try await workflow.discover(url)
            try Task.checkCancellation()
            let draft = try await workflow.updateDraft(id) { draft in
                let merged = SEOAuditSelection.mergeDiscovery(
                    discovered: draft.discoveredPageURLs, selected: Set(draft.selectedPageURLs),
                    found: urls.map(\.absoluteString))
                draft.discoveredPageURLs = merged.discovered
                draft.selectedPageURLs = merged.selected
            }
            return .draft(draft)
        }
    }

    func start(_ id: UUID, lighthouse: Bool?) async throws -> SEOAuditLaunch {
        try await ready()
        _ = try await workflow.project(id)
        let draft = try await workflow.draft(id)
        let urls = SEOAuditSelection.auditURLs(
            discovered: draft.discoveredPageURLs, selected: Set(draft.selectedPageURLs))
        guard !urls.isEmpty, urls.count <= SEOAuditWorkflow.maximumPages else {
            throw SEOAuditInputError(
                "Select between one and \(SEOAuditWorkflow.maximumPages) pages to audit.")
        }
        try requireIdle(id)
        let request = SEOAuditTaskRequest(
            projectID: id, runID: UUID(), urls: urls,
            lighthouse: lighthouse ?? draft.includeLighthouse)
        return launch(request, scoresOnly: false)
    }

    func lighthouse(_ id: UUID, runID: UUID, url: URL) async throws -> SEOAuditLaunch {
        try await ready()
        let project = try await workflow.project(id)
        guard let run = project.runs.first(where: { $0.id == runID }),
            run.pages.contains(where: { $0.url == url.absoluteString })
        else { throw SEOAuditInputError("That page is not in this audit run.") }
        try requireIdle(id)
        return launch(
            SEOAuditTaskRequest(projectID: id, runID: runID, urls: [url], lighthouse: true),
            scoresOnly: true)
    }

    func stop(_ id: UUID) async throws -> [UUID] {
        try await ready()
        _ = try await workflow.project(id)
        let matching = jobs.values.filter { $0.projectID == id }
        guard !matching.isEmpty else {
            throw SEOAuditInputError("No audit is running for this project.")
        }
        for job in matching { job.task.cancel() }
        return matching.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }

    @discardableResult
    func cancel(_ taskID: UUID) -> Bool {
        guard let job = jobs[taskID] else { return false }
        job.task.cancel()
        return true
    }

    func run(_ id: UUID, runID: UUID?, offset: Int) async throws -> SEOAuditRun {
        let project = try await project(id)
        guard let run = SEOAuditSelection.run(in: project, id: runID, offset: offset) else {
            throw SEOAuditInputError("That audit run is not in this project.")
        }
        return run
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        recovery?.cancel()
        listeners.removeAll()
        let pending = Array(jobs.values)
        for job in pending { job.task.cancel() }
        for job in pending { _ = try? await job.task.value }
        jobs.removeAll()
        activities.removeAll()
        await recovery?.value
        recovery = nil
        await workflow.shutdown()
    }

    private func ready() async throws {
        guard !isStopped else { throw SEOAuditInputError("Site Audit is not running.") }
        await recovery?.value
        guard !isStopped else { throw SEOAuditInputError("Site Audit is not running.") }
    }

    private func requireIdle(_ id: UUID) throws {
        guard activities[id] == nil else {
            throw SEOAuditInputError("Wait for this project's audit to finish or cancel it first.")
        }
    }

    private func launch(_ request: SEOAuditTaskRequest, scoresOnly: Bool) -> SEOAuditLaunch {
        let workflow = workflow
        let gate = gate
        let total = request.urls.count
        let url = request.urls.first?.absoluteString ?? ""
        let owner = self
        let job = submit(
            projectID: request.projectID, kind: scoresOnly ? .lighthouse : .audit,
            stage: scoresOnly
                ? .lighthouse(url: url) : .auditing(current: 0, total: total, url: "Queued"),
            runID: request.runID, state: .queued
        ) { [owner] in
            try await gate.acquire()
            do {
                await owner.markRunning(request.projectID)
                let project = try await workflow.run(request, scoresOnly: scoresOnly) {
                    progress in
                    Task { @MainActor [weak owner] in
                        owner?.report(progress, scoresOnly: scoresOnly)
                    }
                }
                await gate.release()
                return .project(project)
            } catch {
                await gate.release()
                throw error
            }
        }
        return SEOAuditLaunch(request: request, job: job, state: .queued)
    }

    private func submit(
        projectID: UUID, kind: SEOAuditJobKind, stage: SEOAuditStage, runID: UUID?,
        state: SEOAuditJobState = .running,
        body: @escaping @Sendable () async throws -> SEOAuditJobResult
    ) -> SEOAuditJob {
        let id = runID.flatMap { kind == .audit ? $0 : nil } ?? UUID()
        let task = Task<SEOAuditJobResult, Error> { try await body() }
        let job = SEOAuditJob(id: id, projectID: projectID, kind: kind, task: task)
        jobs[id] = job
        activities[projectID] = SEOAuditActivity(
            taskID: id, kind: kind, state: state, stage: stage, runID: runID,
            total: kind == .audit ? (stage.total ?? 0) : 0)
        Task { [weak self] in
            let result = await task.result
            self?.finish(job, result: result)
        }
        return job
    }

    private func markRunning(_ projectID: UUID) {
        activities[projectID]?.state = .running
    }

    private func report(_ progress: SEOAuditProgress, scoresOnly: Bool) {
        guard !isStopped else { return }
        let projectID = progress.project.id
        guard var activity = activities[projectID], activity.runID == progress.runID else {
            return
        }
        activity.state = .running
        activity.completed = progress.completed
        activity.total = progress.total
        if !scoresOnly {
            activity.stage = .auditing(
                current: progress.completed, total: progress.total,
                url: progress.url.isEmpty ? "Starting audit" : progress.url)
        }
        activities[projectID] = activity
        publish(.project(progress.project))
    }

    private func finish(_ job: SEOAuditJob, result: Result<SEOAuditJobResult, Error>) {
        guard jobs[job.id] != nil else { return }
        jobs[job.id] = nil
        if activities[job.projectID]?.taskID == job.id { activities[job.projectID] = nil }
        switch result {
        case .success(.project(let project)): publish(.project(project))
        case .success(.draft(let draft)): publish(.draft(job.projectID, draft))
        case .failure:
            guard job.kind != .discover else { return }
            let workflow = workflow
            let projectID = job.projectID
            Task { [weak self] in
                guard let project = try? await workflow.project(projectID), let self,
                    !self.isStopped, self.activities[projectID] == nil
                else { return }
                self.publish(.project(project))
            }
        }
    }

    private func publish(_ event: SEOAuditEvent) {
        for listener in listeners.values { listener(event) }
    }
}

extension SEOAuditStage {
    var total: Int? {
        if case .auditing(_, let total, _) = self { return total }
        return nil
    }
}
