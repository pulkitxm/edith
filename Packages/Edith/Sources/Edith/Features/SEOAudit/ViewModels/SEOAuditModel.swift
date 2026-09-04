import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class SEOAuditModel {
    static let shared = SEOAuditModel()

    var projects: [SEOAuditProjectSummary] = []
    var selectedProject: SEOAuditProject?
    var projectDetailPresented = false
    var selectedRunID: UUID?
    var stage = SEOAuditStage.idle
    var input = ""
    var projectName = ""
    var query = ""
    var pageSelectionQuery = ""
    var severity: SEOAuditSeverity?
    var socialPreviewPlatform = SEOAuditSocialPlatform.facebook
    var lighthouseEnabled = true
    var discoveredPageURLs: [String] = []
    var selectedPageURLs = Set<String>()
    var newProjectPresented = false
    var activeLighthouseURL: String?
    var errorMessage: String?

    @ObservationIgnored private let client: SEOAuditProjectClient
    @ObservationIgnored private let tasks: AgentTaskClient
    @ObservationIgnored private let lighthouse: LighthouseAuditor
    @ObservationIgnored private var auditTask: Task<Void, Never>?
    @ObservationIgnored private var projectRequestID = UUID()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var activeTaskID: UUID?
    private var isMutatingProject = false

    init(
        client: SEOAuditProjectClient = SEOAuditProjectClient(),
        tasks: AgentTaskClient = AgentTaskClient(),
        lighthouse: LighthouseAuditor = LighthouseAuditor()
    ) {
        self.client = client
        self.tasks = tasks
        self.lighthouse = lighthouse
        lighthouseEnabled = lighthouse.isAvailable
    }

    var isRunning: Bool { stage != .idle || isMutatingProject }
    var lighthouseAvailable: Bool { lighthouse.isAvailable }
    var selectedPageCount: Int { selectedPageURLs.intersection(discoveredPageURLs).count }

    var visibleDiscoveredPageURLs: [String] {
        let value = pageSelectionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return discoveredPageURLs }
        return discoveredPageURLs.filter { $0.localizedCaseInsensitiveContains(value) }
    }

    var selectedRun: SEOAuditRun? {
        guard let project = selectedProject else { return nil }
        if let selectedRunID, let run = project.runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return project.latestRun
    }

    var visiblePages: [SEOAuditPageResult] {
        guard let run = selectedRun else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return run.pages.filter { page in
            let matchesQuery =
                trimmedQuery.isEmpty
                || page.url.localizedCaseInsensitiveContains(trimmedQuery)
                || page.metadata.title?.localizedCaseInsensitiveContains(trimmedQuery) == true
            let matchesSeverity =
                severity == nil || page.issues.contains { $0.severity == severity }
            return matchesQuery && matchesSeverity
        }
    }

    func beginNewProject() async {
        guard !isRunning else { return }
        guard let url = SEOAuditURLInput.normalize(input) else {
            errorMessage = "Enter a valid site URL."
            return
        }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = SEOAuditProject(
            name: name.isEmpty ? SEOAuditURLInput.projectName(for: url) : name,
            baseURL: url.absoluteString)
        isMutatingProject = true
        do {
            selectedProject = try await client.create(project)
            refreshSummary(project)
        } catch {
            isMutatingProject = false
            errorMessage = error.localizedDescription
            return
        }
        isMutatingProject = false
        projectDetailPresented = true
        selectedRunID = nil
        discoveredPageURLs = []
        selectedPageURLs = []
        input = ""
        projectName = ""
        newProjectPresented = false
        discoverPages()
    }

    func presentNewProject() {
        guard !isRunning else { return }
        input = ""
        projectName = ""
        newProjectPresented = true
    }

    func leaveForNewProject() {
        guard !isRunning else { return }
        closeProject()
        presentNewProject()
    }

    func selectProject(id: UUID) async {
        if isRunning {
            guard selectedProject?.id == id else { return }
            projectDetailPresented = true
            return
        }
        let requestID = UUID()
        projectRequestID = requestID
        do {
            let project = try await client.project(id)
            try Task.checkCancellation()
            guard projectRequestID == requestID else { return }
            selectedProject = project
            projectDetailPresented = true
            selectedRunID = project.latestRun?.id
            discoveredPageURLs = Self.knownPageURLs(in: project)
            selectedPageURLs = Set(discoveredPageURLs)
            query = ""
            severity = nil
            if let run = project.runs.first(where: { $0.state == .running }) {
                activeTaskID = run.id
                stage = .auditing(
                    current: run.pages.count, total: run.discoveredPageCount,
                    url: "Running in background")
                auditTask = Task { [weak self] in
                    await self?.resumeProject(project.id, runID: run.id)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameProject(id: UUID, to value: String) async {
        guard !isRunning else { return }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Enter a project name."
            return
        }
        isMutatingProject = true
        defer { isMutatingProject = false }
        do {
            let project = try await client.rename(id, name: name)
            if selectedProject?.id == id { selectedProject = project }
            refreshSummary(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProject(id: UUID) async {
        guard !isRunning else { return }
        isMutatingProject = true
        defer { isMutatingProject = false }
        do {
            try await client.delete(id)
            projects.removeAll { $0.id == id }
            if selectedProject?.id == id {
                isMutatingProject = false
                closeProject()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeProject() {
        projectDetailPresented = false
        guard !isRunning else { return }
        selectedProject = nil
        selectedRunID = nil
        discoveredPageURLs = []
        selectedPageURLs = []
        query = ""
        severity = nil
    }

    func runAgain() {
        selectAllPages()
        auditSelectedPages()
    }

    func discoverPages() {
        guard let project = selectedProject,
            let url = SEOAuditURLInput.normalize(project.baseURL), !isRunning
        else { return }
        stage = .discovering
        auditTask?.cancel()
        auditTask = Task { [weak self] in
            guard let self else { return }
            await executeDiscovery(startURL: url)
        }
    }

    func auditSelectedPages() {
        guard var project = selectedProject, !isRunning else { return }
        let selected = Set(selectedPageURLs)
        var urls: [URL] = []
        for value in discoveredPageURLs where selected.contains(value) {
            if let url = URL(string: value) { urls.append(url) }
        }
        guard !urls.isEmpty else {
            errorMessage = "Select at least one page to audit."
            return
        }
        let newRun = SEOAuditRun()
        project.runs.insert(newRun, at: 0)
        project.updatedAt = Date()
        selectedProject = project
        selectedRunID = newRun.id
        run(project: project, runID: newRun.id, urls: urls)
    }

    func togglePage(_ url: String) {
        if selectedPageURLs.contains(url) {
            selectedPageURLs.remove(url)
        } else {
            selectedPageURLs.insert(url)
        }
    }

    func selectAllPages() {
        selectedPageURLs = Set(discoveredPageURLs)
    }

    func deselectAllPages() {
        selectedPageURLs.removeAll()
    }

    func runLighthouse(for page: SEOAuditPageResult) {
        guard lighthouseAvailable, !isRunning, let url = URL(string: page.url),
            let project = selectedProject, let runID = selectedRunID
        else { return }
        activeLighthouseURL = page.url
        stage = .lighthouse(url: page.url)
        auditTask?.cancel()
        let taskID = UUID()
        activeTaskID = taskID
        auditTask = Task {
            defer {
                activeTaskID = nil
                activeLighthouseURL = nil
                stage = .idle
                auditTask = nil
            }
            do {
                let request = SEOAuditTaskRequest(
                    projectID: project.id, runID: runID, urls: [url], lighthouse: true)
                let data = try await tasks.run(
                    AgentTaskSubmission(
                        id: taskID, operation: SEOAuditTaskOperation.lighthouse,
                        title: "Lighthouse audit",
                        payload: AgentPayload.encode(request)))
                try Task.checkCancellation()
                let completed = try AgentPayload.decode(SEOAuditProject.self, from: data)
                guard selectedProject?.id == project.id else { return }
                selectedProject = completed
                refreshSummary(completed)
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        guard let id = activeTaskID else { return }
        Task {
            do { _ = try await tasks.cancel(id) } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSelectedProject() async {
        guard let project = selectedProject, !isRunning else { return }
        await deleteProject(id: project.id)
    }

    func selectRun(_ id: UUID) {
        selectedRunID = id
        query = ""
        severity = nil
    }

    func history(for page: SEOAuditPageResult) -> [SEOAuditPageResult] {
        guard let project = selectedProject, let run = selectedRun else { return [] }
        return project.history(for: page.url, excluding: run.id)
    }

    private func run(project: SEOAuditProject, runID: UUID, urls: [URL]) {
        let request = SEOAuditTaskRequest(
            projectID: project.id, runID: runID, urls: urls, lighthouse: lighthouseEnabled)
        stage = .auditing(current: 0, total: urls.count, url: "Queued in background")
        auditTask?.cancel()
        auditTask = Task { [weak self] in
            guard let self else { return }
            await execute(request, projectName: project.name)
        }
    }

    private func executeDiscovery(startURL: URL) async {
        stage = .discovering
        let taskID = UUID()
        activeTaskID = taskID
        defer { activeTaskID = nil }
        do {
            let data = try await tasks.run(
                AgentTaskSubmission(
                    id: taskID, operation: SEOAuditTaskOperation.discover,
                    title: "Discover site pages",
                    payload: AgentPayload.encode(startURL)))
            let urls = try AgentPayload.decode([URL].self, from: data)
            try Task.checkCancellation()
            let values = urls.map(\.absoluteString)
            let previous = Set(discoveredPageURLs)
            discoveredPageURLs = Self.unique(discoveredPageURLs + values)
            selectedPageURLs.formUnion(Set(values).subtracting(previous))
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        stage = .idle
        auditTask = nil
    }

    private func execute(_ request: SEOAuditTaskRequest, projectName: String) async {
        let projectID = request.projectID
        activeTaskID = request.runID
        progressTask?.cancel()
        progressTask = Task { [weak self] in await self?.observeProject(request) }
        defer {
            activeTaskID = nil
            progressTask?.cancel()
            progressTask = nil
        }
        do {
            let data = try await tasks.run(
                AgentTaskSubmission(
                    id: request.runID, operation: SEOAuditTaskOperation.audit,
                    title: "Audit \(projectName)",
                    payload: AgentPayload.encode(request))
            )
            try Task.checkCancellation()
            let completed = try AgentPayload.decode(SEOAuditProject.self, from: data)
            if selectedProject?.id == projectID {
                selectedProject = completed
                refreshSummary(completed)
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            if let saved = try? await client.project(projectID),
                selectedProject?.id == projectID
            {
                selectedProject = saved
                refreshSummary(saved)
            }
        }
        stage = .idle
        auditTask = nil
    }

    private func resumeProject(_ projectID: UUID, runID: UUID) async {
        defer {
            activeTaskID = nil
            auditTask = nil
            stage = .idle
        }
        while !Task.isCancelled {
            do {
                let saved = try await client.project(projectID)
                try Task.checkCancellation()
                guard selectedProject?.id == projectID else { return }
                selectedProject = saved
                refreshSummary(saved)
                guard let run = saved.runs.first(where: { $0.id == runID }), run.state == .running
                else { return }
                stage = .auditing(
                    current: run.pages.count, total: run.discoveredPageCount,
                    url: run.pages.last?.url ?? "Starting audit")
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError { return } catch {
                errorMessage = error.localizedDescription
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func observeProject(_ request: SEOAuditTaskRequest) async {
        while !Task.isCancelled {
            do {
                let saved = try await client.project(request.projectID)
                try Task.checkCancellation()
                if selectedProject?.id == request.projectID,
                    let run = saved.runs.first(where: { $0.id == request.runID })
                {
                    selectedProject = saved
                    refreshSummary(saved)
                    stage = .auditing(
                        current: run.pages.count, total: request.urls.count,
                        url: run.pages.last?.url ?? "Starting audit")
                }
            } catch is CancellationError { return } catch {}
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func refreshSummary(_ project: SEOAuditProject) {
        projects.removeAll { $0.id == project.id }
        projects.append(SEOAuditProjectSummary(project: project))
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func knownPageURLs(in project: SEOAuditProject) -> [String] {
        var values: [String] = []
        for run in project.runs {
            for page in run.pages { values.append(page.url) }
        }
        return unique(values)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    func refreshProjects() async {
        do {
            let value = try await client.projects()
            try Task.checkCancellation()
            projects = value
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}
