import EdithExtensionSupport
import Foundation
import Observation

enum SEOAuditJobState: String, Codable, Sendable {
    case queued
    case running
}

struct SEOAuditActivity: Codable, Equatable, Sendable {
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

final class SEOAuditGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if !busy {
                        busy = true; continuation.resume()
                    } else {
                        waiters.append((id, continuation))
                    }
                }
            }
        } onCancel: {
            self.abandon(id)
        }
    }

    func release() {
        lock.withLock {
            guard !waiters.isEmpty else { busy = false; return }
            waiters.removeFirst().continuation.resume()
        }
    }

    var waiting: Int { lock.withLock { waiters.count } }

    private func abandon(_ id: UUID) {
        lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
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
    @ObservationIgnored private let auditGate = SEOAuditGate()
    @ObservationIgnored private let lighthouseGate = SEOAuditGate()
    @ObservationIgnored private let remote: SEOAuditUIBridge?
    @ObservationIgnored private var remoteObservation: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let callbacks = SEOAuditCallbacks()

    init(workflow: SEOAuditWorkflow = SEOAuditWorkflow(), remote: SEOAuditUIBridge? = nil) {
        self.workflow = workflow
        self.remote = remote
        guard remote == nil else { return }
        recovery = Task { try? await workflow.recoverInterruptedRuns() }
    }

    var jobCount: Int { jobs.count }
    var listenerCount: Int { listeners.count }

    func observe(_ listener: @escaping (SEOAuditEvent) -> Void) -> UUID {
        let id = UUID()
        guard !isStopped else { return id }
        listeners[id] = listener
        if let remote, remoteObservation == nil {
            remoteObservation = Task { [weak self] in
                var seen: [UUID: Date] = [:]
                var previousActive: Set<UUID> = []
                while !Task.isCancelled {
                    do {
                        let poll = try await remote.poll()
                        guard let self, !isStopped, !Task.isCancelled else { return }
                        activities = poll.activities
                        let stamps = poll.summaries.reduce(into: [UUID: Date]()) {
                            $0[$1.id] = $1.updatedAt
                        }
                        let active = Set(poll.activities.keys)
                        var refresh = active.filter { stamps[$0] != nil && stamps[$0] != seen[$0] }
                        refresh.formUnion(
                            previousActive.subtracting(active).filter { stamps[$0] != nil })
                        seen = stamps
                        previousActive = active
                        for id in refresh {
                            let project: SEOAuditProject = try await remote.call(
                                "project", id: id)
                            guard !isStopped, !Task.isCancelled else { return }
                            publish(.project(project))
                        }
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
            }
        }
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
        if let remote { return (try? await remote.call("available", as: Bool.self)) ?? false }
        return await workflow.lighthouseAuditor.isAvailable()
    }

    func list() async throws -> [SEOAuditProjectSummary] {
        if let remote { return try await remote.call("list") }
        try await ready()
        return try await workflow.projects()
    }

    func project(_ id: UUID) async throws -> SEOAuditProject {
        if let remote { return try await remote.call("project", id: id) }
        try await ready()
        return try await workflow.project(id)
    }

    func create(url: String, name: String?) async throws -> SEOAuditProject {
        try await create(SEOAuditSelection.makeProject(url: url, name: name))
    }

    func create(_ project: SEOAuditProject) async throws -> SEOAuditProject {
        if let remote { return try await remote.call("create", project: project) }
        try await ready()
        let created = try await workflow.create(project)
        publish(.project(created))
        return created
    }

    func rename(_ id: UUID, name: String) async throws -> SEOAuditProject {
        if let remote { return try await remote.call("rename", id: id, name: name) }
        try await ready()
        try requireIdle(id)
        let project = try await workflow.rename(id, name: name)
        publish(.project(project))
        return project
    }

    func delete(_ id: UUID) async throws {
        if let remote { let _: Bool = try await remote.call("delete", id: id); return }
        try await ready()
        try requireIdle(id)
        try await workflow.delete(id)
        publish(.deleted(id))
    }

    func draft(_ id: UUID) async throws -> SEOAuditDraft {
        if let remote { return try await remote.call("draft", id: id) }
        try await ready()
        return try await workflow.draft(id)
    }

    func setDraft(_ id: UUID, _ draft: SEOAuditDraft) async throws -> SEOAuditDraft {
        if let remote { return try await remote.call("setDraft", id: id, draft: draft) }
        try await ready()
        let saved = try await workflow.setDraft(id, draft)
        publish(.draft(id, saved))
        return saved
    }

    func choose(_ id: UUID, edit: SEOAuditPageEdit) async throws -> SEOAuditDraft {
        if let remote { return try await remote.call("choose", id: id, edit: edit) }
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
        if let remote { return try await remote.call("setLighthouse", id: id, enabled: enabled) }
        try await ready()
        let draft = try await workflow.updateDraft(id) { $0.includeLighthouse = enabled }
        publish(.draft(id, draft))
        return draft
    }

    func discover(_ id: UUID) async throws -> SEOAuditJob {
        if let remote {
            let launch: SEOAuditUIJob = try await remote.call("discover", id: id);
            return retainRemote(remote.job(launch))
        }
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
        if let remote {
            let launch: SEOAuditUIJob = try await remote.call("start", id: id, enabled: lighthouse);
            guard let request = launch.request else { throw ExtensionPeerError.invalidRequest };
            return .init(
                request: request, job: retainRemote(remote.job(launch)), state: launch.state)
        }
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
        if let remote {
            let launch: SEOAuditUIJob = try await remote.call(
                "lighthouse", id: id, runID: runID, url: url)
                ;
            guard let request = launch.request else { throw ExtensionPeerError.invalidRequest };
            return .init(
                request: request, job: retainRemote(remote.job(launch)), state: launch.state)
        }
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
        if let remote { return try await remote.call("stop", id: id) }
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
        if let remote {
            launch { let _: Bool? = try? await remote.call("cancel", id: taskID) }
            return true
        }
        guard let job = jobs[taskID] else { return false }
        job.task.cancel()
        return true
    }

    func run(_ id: UUID, runID: UUID?, offset: Int) async throws -> SEOAuditRun {
        if let remote { return try await remote.call("run", id: id, runID: runID, offset: offset) }
        let project = try await project(id)
        guard let run = SEOAuditSelection.run(in: project, id: runID, offset: offset) else {
            throw SEOAuditInputError("That audit run is not in this project.")
        }
        return run
    }

    func beginSuspension() {
        isStopped = true
        callbacks.close()
        remoteObservation?.cancel()
        recovery?.cancel()
        for job in jobs.values { job.task.cancel() }
        for task in tasks.values { task.cancel() }
    }

    func suspendAndWait() async {
        beginSuspension()
        let pending = Array(jobs.values)
        let callbacksTasks = Array(tasks.values)
        let observation = remoteObservation, recovery = recovery
        for job in pending { _ = await job.task.result }
        for task in callbacksTasks { await task.value }
        await observation?.value
        await recovery?.value
        await callbacks.wait()
        await remote?.drain()
    }

    func shutdown() async {
        await suspendAndWait()
        listeners.removeAll()
        remoteObservation = nil
        jobs.removeAll()
        activities.removeAll()
        await recovery?.value
        recovery = nil
        if remote == nil { await workflow.shutdown() }
    }

    private func retainRemote(_ job: SEOAuditJob) -> SEOAuditJob {
        jobs[job.id] = job
        if isStopped { job.task.cancel() }
        launch { [self] in
            _ = await job.task.result
            jobs[job.id] = nil
        }
        return job
    }

    private func ready() async throws {
        guard !isStopped else { throw SEOAuditInputError("Site Audit is not running.") }
        await recovery?.value
        guard !isStopped else { throw SEOAuditInputError("Site Audit is not running.") }
    }

    private func requireIdle(_ id: UUID) throws {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        guard activities[id] == nil else {
            throw SEOAuditInputError("Wait for this project's audit to finish or cancel it first.")
        }
    }

    private func launch(_ request: SEOAuditTaskRequest, scoresOnly: Bool) -> SEOAuditLaunch {
        let workflow = workflow
        let gate = scoresOnly ? lighthouseGate : auditGate
        let total = request.urls.count
        let url = request.urls.first?.absoluteString ?? ""
        let owner = self
        let callbacks = callbacks
        let job = submit(
            projectID: request.projectID, kind: scoresOnly ? .lighthouse : .audit,
            stage: scoresOnly
                ? .lighthouse(url: url)
                : .auditing(current: 0, total: total, url: "Queued in background"),
            runID: request.runID, state: .queued
        ) { [owner] in
            try await gate.acquire()
            do {
                await owner.markRunning(request.projectID)
                let project = try await workflow.run(request, scoresOnly: scoresOnly) {
                    progress in
                    callbacks.submit { [weak owner] in
                        owner?.report(progress, scoresOnly: scoresOnly)
                    }
                }
                gate.release()
                return .project(project)
            } catch {
                gate.release()
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
        let task = Task<SEOAuditJobResult, Error> {
            try Task.checkCancellation()
            return try await body()
        }
        if isStopped { task.cancel() }
        let job = SEOAuditJob(id: id, projectID: projectID, kind: kind, task: task)
        jobs[id] = job
        activities[projectID] = SEOAuditActivity(
            taskID: id, kind: kind, state: state, stage: stage, runID: runID,
            total: kind == .audit ? (stage.total ?? 0) : 0)
        launch { [weak self] in
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
        guard !isStopped else { return }
        switch result {
        case .success(.project(let project)): publish(.project(project))
        case .success(.draft(let draft)): publish(.draft(job.projectID, draft))
        case .failure:
            guard job.kind != .discover else { return }
            let workflow = workflow
            let projectID = job.projectID
            launch { [weak self] in
                guard let project = try? await workflow.project(projectID), let self,
                    !self.isStopped, self.activities[projectID] == nil
                else { return }
                self.publish(.project(project))
            }
        }
    }

    private func launch(_ operation: @escaping @MainActor () async -> Void) {
        guard !isStopped else { return }
        let id = UUID()
        tasks[id] = Task { [self] in
            defer { tasks[id] = nil }
            await operation()
        }
    }

    private func publish(_ event: SEOAuditEvent) {
        guard !isStopped else { return }
        for listener in listeners.values { listener(event) }
    }
}

extension SEOAuditStage {
    var total: Int? {
        if case .auditing(_, let total, _) = self { return total }
        return nil
    }
}

private final class SEOAuditCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private let pending = DispatchGroup()
    private var closed = false

    func submit(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock {
            guard !closed else { return }
            pending.enter()
            DispatchQueue.main.async { [self] in
                defer { pending.leave() }
                operation()
            }
        }
    }

    func close() { lock.withLock { closed = true } }

    func wait() async {
        await withCheckedContinuation { continuation in
            pending.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}
