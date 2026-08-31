import Foundation
import Observation

@MainActor
@Observable
final class SEOAuditModel {
    var projects: [SEOAuditProjectSummary] = []
    var selectedProject: SEOAuditProject?
    var selectedRunID: UUID?
    var stage = SEOAuditStage.idle
    var input = ""
    var projectName = ""
    var query = ""
    var severity: SEOAuditSeverity?
    var lighthouseEnabled = true
    var errorMessage: String?

    @ObservationIgnored private let repository: SEOAuditRepository
    @ObservationIgnored private let crawler: SitemapCrawler
    @ObservationIgnored private let pageAuditor: SEOPageAuditor
    @ObservationIgnored private let lighthouse: LighthouseAuditor
    @ObservationIgnored private var auditTask: Task<Void, Never>?

    init(
        repository: SEOAuditRepository = SEOAuditRepository(),
        crawler: SitemapCrawler = SitemapCrawler(),
        pageAuditor: SEOPageAuditor = SEOPageAuditor(),
        lighthouse: LighthouseAuditor = LighthouseAuditor()
    ) {
        self.repository = repository
        self.crawler = crawler
        self.pageAuditor = pageAuditor
        self.lighthouse = lighthouse
        lighthouseEnabled = lighthouse.isAvailable
        projects = (try? repository.loadSummaries()) ?? []
    }

    var isRunning: Bool { stage != .idle }
    var lighthouseAvailable: Bool { lighthouse.isAvailable }

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

    func beginNewProject() {
        guard let url = SEOAuditURLInput.normalize(input) else {
            errorMessage = "Enter a valid site URL."
            return
        }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        var project = SEOAuditProject(
            name: name.isEmpty ? SEOAuditURLInput.projectName(for: url) : name,
            baseURL: url.absoluteString)
        project.runs.insert(SEOAuditRun(), at: 0)
        selectedProject = project
        selectedRunID = project.runs[0].id
        input = ""
        projectName = ""
        run(projectID: project.id, startURL: url)
    }

    func selectProject(id: UUID) {
        do {
            let project = try repository.loadProject(id: id)
            selectedProject = project
            selectedRunID = project.latestRun?.id
            query = ""
            severity = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeProject() {
        guard !isRunning else { return }
        selectedProject = nil
        selectedRunID = nil
        query = ""
        severity = nil
    }

    func runAgain() {
        guard var project = selectedProject,
            let url = SEOAuditURLInput.normalize(project.baseURL), !isRunning
        else { return }
        let newRun = SEOAuditRun()
        project.runs.insert(newRun, at: 0)
        project.updatedAt = Date()
        selectedProject = project
        selectedRunID = newRun.id
        run(projectID: project.id, startURL: url)
    }

    func cancel() {
        auditTask?.cancel()
    }

    func deleteSelectedProject() {
        guard let project = selectedProject, !isRunning else { return }
        do {
            try repository.delete(id: project.id)
            projects.removeAll { $0.id == project.id }
            selectedProject = nil
            selectedRunID = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func run(projectID: UUID, startURL: URL) {
        auditTask?.cancel()
        auditTask = Task { [weak self] in
            guard let self else { return }
            await execute(projectID: projectID, startURL: startURL)
        }
    }

    private func execute(projectID: UUID, startURL: URL) async {
        stage = .discovering
        saveSelectedProject()
        do {
            let urls = try await crawler.pages(startingAt: startURL)
            try Task.checkCancellation()
            updateRun { $0.discoveredPageCount = urls.count }
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                stage = .auditing(current: index + 1, total: urls.count, url: url.absoluteString)
                var page = await pageAuditor.audit(url)
                if lighthouseEnabled {
                    let result = await lighthouse.audit(url)
                    page = page.with(scores: result.scores, lighthouseError: result.error)
                }
                updateRun { $0.pages.append(page) }
                if selectedProject?.imageURL == nil, let imageURL = page.metadata.openGraphImageURL
                {
                    selectedProject?.imageURL = imageURL
                }
                selectedProject?.updatedAt = Date()
                if index.isMultiple(of: 25) { saveSelectedProject() }
            }
            stage = .saving
            updateRun {
                $0.state = .completed
                $0.finishedAt = Date()
            }
        } catch is CancellationError {
            updateRun {
                $0.state = .cancelled
                $0.finishedAt = Date()
            }
        } catch {
            updateRun {
                $0.state = .failed
                $0.finishedAt = Date()
                $0.error = error.localizedDescription
            }
            errorMessage = error.localizedDescription
        }
        selectedProject?.updatedAt = Date()
        saveSelectedProject()
        stage = .idle
        auditTask = nil
        if selectedProject?.id != projectID { return }
    }

    private func updateRun(_ mutation: (inout SEOAuditRun) -> Void) {
        guard let runID = selectedRunID,
            let index = selectedProject?.runs.firstIndex(where: { $0.id == runID })
        else { return }
        mutation(&selectedProject!.runs[index])
    }

    private func saveSelectedProject() {
        guard let project = selectedProject else { return }
        do {
            try repository.save(project)
            projects.removeAll { $0.id == project.id }
            projects.append(SEOAuditProjectSummary(project: project))
            projects.sort { $0.updatedAt > $1.updatedAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
