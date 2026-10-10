import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class SEOAuditModel {
    static var shared = SEOAuditModel()

    var projects: [SEOAuditProjectSummary] = []
    let projectsLoad = ContentLoad()
    var projectsLoaded: Bool { projectsLoad.hasContent }
    var loadingProjects: Bool { projectsLoad.isRunning }
    var projectsLoadError: String? { projectsLoad.errorMessage }
    var selectedProject: SEOAuditProject?
    var projectDetailPresented = false
    var selectedRunID: UUID?
    var stage = SEOAuditStage.idle
    var input = ""
    var projectName = ""
    var query = "" { didSet { if query != oldValue { schedulePageFilter() } } }
    var pageSelectionQuery = ""
    var severity: SEOAuditSeverity? { didSet { if severity != oldValue { schedulePageFilter() } } }
    var socialPreviewPlatform = SEOAuditSocialPlatform.facebook
    var lighthouseEnabled = true {
        didSet {
            guard !isApplyingDraft, selectedProject != nil, lighthouseEnabled != oldValue else {
                return
            }
            persistDraft()
        }
    }
    var discoveredPageURLs: [String] = []
    var selectedPageURLs = Set<String>()
    var newProjectPresented = false
    var activeLighthouseURL: String?
    var errorMessage: String?

    @ObservationIgnored private let service: SEOAuditService
    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    private(set) var lighthouseAvailable = false
    @ObservationIgnored private var auditTask: Task<Void, Never>?
    @ObservationIgnored private var projectRequestID = UUID()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var activeTaskID: UUID?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    private var isMutatingProject = false
    private var indexGeneration = 0
    private var filterGeneration = 0
    private var filterEntries: [SEOPageFilterEntry] = []
    private var pagesByID: [UUID: SEOAuditPageResult] = [:]
    private var isApplyingDraft = false

    init(service: SEOAuditService? = nil) {
        self.service = service ?? SEOAuditWorkerOperations.service ?? SEOAuditService()
        observerID = self.service.observe { [weak self] event in self?.receive(event) }
    }

    private func receive(_ event: SEOAuditEvent) {
        switch event {
        case .project(let project):
            refreshSummary(project)
            guard selectedProject?.id == project.id else { return }
            selectedProject = project
            if let id = selectedRunID, !project.runs.contains(where: { $0.id == id }) {
                selectedRunID = project.latestRun?.id
            }
            stage = service.activity(for: project.id)?.stage ?? .idle
            scheduleIndexRebuild()
        case .draft(let id, let draft):
            guard let project = selectedProject, project.id == id else { return }
            applyDraft(draft, fallback: project)
        case .deleted(let id):
            projects.removeAll { $0.id == id }
            guard selectedProject?.id == id else { return }
            selectedProject = nil; selectedRunID = nil; projectDetailPresented = false
            discoveredPageURLs = []; selectedPageURLs = []; stage = .idle
            scheduleIndexRebuild()
        }
    }

    var isRunning: Bool { stage != .idle || isMutatingProject }
    var selectedPageCount: Int { selectedPageURLs.intersection(discoveredPageURLs).count }

    var visibleDiscoveredPageURLs: [String] {
        let value = pageSelectionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return discoveredPageURLs }
        return discoveredPageURLs.filter { $0.localizedCaseInsensitiveContains(value) }
    }

    private(set) var visiblePages: [SEOAuditPageResult] = []
    private(set) var historyByURL: [String: [SEOAuditPageResult]] = [:]
    private(set) var indexBuildCount = 0
    private(set) var completedFilters: [String] = []

    var selectedRun: SEOAuditRun? {
        guard let project = selectedProject else { return nil }
        if let selectedRunID, let run = project.runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return project.latestRun
    }

    func beginNewProject() async {
        guard !isRunning else { return }
        let project: SEOAuditProject
        do {
            project = try SEOAuditSelection.makeProject(url: input, name: projectName)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isMutatingProject = true
        do {
            selectedProject = try await service.create(project)
            await rebuildPageIndex()
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
            let project = try await service.project(id)
            try Task.checkCancellation()
            guard projectRequestID == requestID else { return }
            selectedProject = project
            projectDetailPresented = true
            selectedRunID = project.latestRun?.id
            applyDraft(try? await service.draft(id), fallback: project)
            query = ""
            severity = nil
            await rebuildPageIndex()
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
            let project = try await service.rename(id, name: name)
            if selectedProject?.id == id {
                selectedProject = project
                await rebuildPageIndex()
            }
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
            try await service.delete(id)
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
        scheduleIndexRebuild()
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
        let urls = SEOAuditSelection.auditURLs(
            discovered: discoveredPageURLs, selected: selectedPageURLs)
        guard !urls.isEmpty else {
            errorMessage = "Select at least one page to audit."
            return
        }
        let newRun = SEOAuditRun()
        project.runs.insert(newRun, at: 0)
        project.updatedAt = Date()
        selectedProject = project
        scheduleIndexRebuild()
        selectedRunID = newRun.id
        run(project: project, runID: newRun.id, urls: urls)
    }

    func togglePage(_ url: String) {
        if selectedPageURLs.contains(url) {
            selectedPageURLs.remove(url)
        } else {
            selectedPageURLs.insert(url)
        }
        persistDraft()
    }

    func selectAllPages() {
        selectedPageURLs = Set(discoveredPageURLs)
        persistDraft()
    }

    func deselectAllPages() {
        selectedPageURLs.removeAll()
        persistDraft()
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
                let launch = try await service.lighthouse(project.id, runID: runID, url: url)
                activeTaskID = launch.job.id
                guard
                    case .project(let completed) = try await launch.job.value(
                        cancellingOnCancel: false)
                else { throw SEOAuditInputError("Lighthouse returned no project.") }
                try Task.checkCancellation()
                guard selectedProject?.id == project.id else { return }
                selectedProject = completed
                scheduleIndexRebuild()
                refreshSummary(completed)
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        guard let id = activeTaskID else { return }
        _ = service.cancel(id)
    }

    func shutdown() {
        service.stopObserving(observerID); observerID = nil
        projectsLoad.cancel(); auditTask?.cancel(); progressTask?.cancel()
        indexTask?.cancel(); filterTask?.cancel(); draftTask?.cancel()
        projectRequestID = UUID(); indexGeneration += 1; filterGeneration += 1
    }

    func drain() async {
        let pending = [auditTask, progressTask, indexTask, filterTask, draftTask]
        for task in pending { await task?.value }
        auditTask = nil; progressTask = nil; indexTask = nil; filterTask = nil; draftTask = nil
        selectedProject = nil; projects = []; visiblePages = []; historyByURL = [:]
        pagesByID = [:]; filterEntries = []; discoveredPageURLs = []; selectedPageURLs = []
    }

    func deleteSelectedProject() async {
        guard let project = selectedProject, !isRunning else { return }
        await deleteProject(id: project.id)
    }

    func selectRun(_ id: UUID) {
        selectedRunID = id
        query = ""
        severity = nil
        scheduleIndexRebuild()
    }

    func open(_ project: SEOAuditProject) async {
        selectedProject = project
        selectedRunID = project.latestRun?.id
        query = ""
        severity = nil
        await rebuildPageIndex()
    }

    func history(for page: SEOAuditPageResult) -> [SEOAuditPageResult] {
        historyByURL[page.url] ?? []
    }

    private func scheduleIndexRebuild() {
        indexTask?.cancel()
        let generation = beginIndexBuild()
        let project = selectedProject
        let runID = selectedRun?.id
        indexTask = Task { [weak self] in
            let built = await SEOPageIndex.work {
                SEOPageIndex.build(project: project, runID: runID)
            }
            guard let self, !Task.isCancelled, generation == self.indexGeneration else { return }
            self.apply(built)
        }
    }

    private func rebuildPageIndex() async {
        indexTask?.cancel()
        let generation = beginIndexBuild()
        let project = selectedProject
        let runID = selectedRun?.id
        let built = await SEOPageIndex.work {
            SEOPageIndex.build(project: project, runID: runID)
        }
        guard !Task.isCancelled, generation == indexGeneration else { return }
        apply(built)
    }

    private func beginIndexBuild() -> Int {
        filterTask?.cancel()
        indexGeneration &+= 1
        indexBuildCount += 1
        return indexGeneration
    }

    private func apply(_ built: SEOPageIndexSnapshot) {
        filterEntries = built.entries
        pagesByID = built.pages
        historyByURL = built.history
        visiblePages = built.ordered
        if hasActiveFilter { schedulePageFilter() }
    }

    private var hasActiveFilter: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || severity != nil
    }

    private func schedulePageFilter() {
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration
        let query = query
        let severity = severity
        let entries = filterEntries
        let pages = pagesByID
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = await SEOPageIndex.work {
                SEOPageIndex.matchingIDs(entries, query: query, severity: severity)
            }
            guard !Task.isCancelled, generation == self.filterGeneration else { return }
            self.visiblePages = ids.compactMap { pages[$0] }
            self.completedFilters.append(query)
        }
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
            guard let projectID = selectedProject?.id else { return }
            let job = try await service.discover(projectID)
            activeTaskID = job.id
            guard case .draft(let draft) = try await job.value(cancellingOnCancel: false) else {
                throw SEOAuditInputError("Discovery returned no pages.")
            }
            let urls = draft.discoveredPageURLs.compactMap(URL.init(string:))
            try Task.checkCancellation()
            let merged = SEOAuditSelection.mergeDiscovery(
                discovered: discoveredPageURLs, selected: selectedPageURLs,
                found: urls.map(\.absoluteString))
            discoveredPageURLs = merged.discovered
            selectedPageURLs = Set(merged.selected)
            persistDraft()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        stage = .idle
        auditTask = nil
    }

    private func execute(_ request: SEOAuditTaskRequest, projectName: String) async {
        let projectID = request.projectID
        defer {
            activeTaskID = nil; progressTask?.cancel(); progressTask = nil
        }
        do {
            await draftTask?.value
            let draft = SEOAuditDraft(
                discoveredPageURLs: discoveredPageURLs,
                selectedPageURLs: request.urls.map(\.absoluteString),
                includeLighthouse: request.lighthouse)
            _ = try await service.setDraft(projectID, draft)
            let launch = try await service.start(projectID, lighthouse: request.lighthouse)
            if selectedProject?.id == projectID { selectedRunID = launch.request.runID }
            activeTaskID = launch.job.id
            progressTask?.cancel()
            progressTask = Task { [weak self] in await self?.observeProject(launch.request) }
            guard
                case .project(let completed) = try await launch.job.value(cancellingOnCancel: false)
            else { throw SEOAuditInputError("Audit returned no project.") }
            try Task.checkCancellation()
            if selectedProject?.id == projectID {
                selectedProject = completed
                refreshSummary(completed)
                scheduleIndexRebuild()
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            if let saved = try? await service.project(projectID),
                selectedProject?.id == projectID
            {
                selectedProject = saved
                refreshSummary(saved)
                scheduleIndexRebuild()
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
                let saved = try await service.project(projectID)
                try Task.checkCancellation()
                guard selectedProject?.id == projectID else { return }
                selectedProject = saved
                refreshSummary(saved)
                scheduleIndexRebuild()
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
                let saved = try await service.project(request.projectID)
                try Task.checkCancellation()
                if selectedProject?.id == request.projectID,
                    let run = saved.runs.first(where: { $0.id == request.runID })
                {
                    selectedProject = saved
                    refreshSummary(saved)
                    scheduleIndexRebuild()
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

    private func applyDraft(_ draft: SEOAuditDraft?, fallback: SEOAuditProject) {
        isApplyingDraft = true
        defer { isApplyingDraft = false }
        if let draft, !draft.discoveredPageURLs.isEmpty {
            discoveredPageURLs = draft.discoveredPageURLs
            selectedPageURLs = Set(draft.selectedPageURLs)
            lighthouseEnabled = draft.includeLighthouse
        } else {
            discoveredPageURLs = SEOAuditSelection.knownPageURLs(in: fallback)
            selectedPageURLs = Set(discoveredPageURLs)
        }
    }

    private func persistDraft() {
        guard let id = selectedProject?.id, !isApplyingDraft else { return }
        let discovered = discoveredPageURLs
        let selected = discovered.filter { selectedPageURLs.contains($0) }
        let lighthouse = lighthouseEnabled
        draftTask?.cancel()
        draftTask = Task { [service] in
            guard var draft = try? await service.draft(id) else { return }
            draft.discoveredPageURLs = discovered
            draft.selectedPageURLs = selected
            draft.includeLighthouse = lighthouse
            guard !Task.isCancelled else { return }
            _ = try? await service.setDraft(id, draft)
        }
    }

    func refreshProjects() async {
        guard !loadingProjects else { return }
        let request = projectsLoad.begin()
        defer { if Task.isCancelled { projectsLoad.cancel(request) } }
        do {
            lighthouseAvailable = await service.lighthouseAvailable()
            let value = try await service.list()
            try Task.checkCancellation()
            guard projectsLoad.isCurrent(request) else { return }
            projects = value
            projectsLoad.complete(request)
        } catch {
            projectsLoad.fail(request, error: error)
        }
    }
}
