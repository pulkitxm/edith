import Foundation

enum SEOAuditJobKind: String, Codable, Sendable {
    case discover
    case audit
    case lighthouse
}

struct SEOAuditTaskRequest: Codable, Sendable {
    let projectID: UUID
    let runID: UUID
    let urls: [URL]
    let lighthouse: Bool
}

struct SEOAuditProgress: Sendable {
    let project: SEOAuditProject
    let runID: UUID
    let completed: Int
    let total: Int
    let url: String
}

actor SEOAuditWorkflow {
    static let maximumPages = 1_000
    static let siteConcurrency = 4

    private let repository: SEOAuditRepository
    private let crawler: SitemapCrawler
    private let auditor: SEOPageAuditor
    private let lighthouse: LighthouseAuditor
    private let images: SEOAuditImageStore
    private var active: Set<UUID> = []
    private let network: SEOAuditHTTPClient

    init(
        repository: SEOAuditRepository = SEOAuditRepository(),
        crawler: SitemapCrawler? = nil, auditor: SEOPageAuditor? = nil,
        network: SEOAuditHTTPClient = SEOAuditHTTPClient(),
        lighthouse: LighthouseAuditor = LighthouseAuditor(),
        images: SEOAuditImageStore? = nil
    ) {
        self.repository = repository
        self.network = network
        self.crawler = crawler ?? SitemapCrawler(session: network)
        self.auditor = auditor ?? SEOPageAuditor(session: network)
        self.lighthouse = lighthouse
        self.images = images ?? SEOAuditImageStore(root: repository.root, session: network)
    }

    func shutdown() { network.shutdown() }

    nonisolated var lighthouseAuditor: LighthouseAuditor { lighthouse }

    func recoverInterruptedRuns() throws {
        for summary in try repository.loadSummaries() {
            guard var project = try? repository.loadProject(id: summary.id),
                !active.contains(project.id)
            else { continue }
            var changed = false
            for index in project.runs.indices where project.runs[index].state == .running {
                project.runs[index].state = .failed
                project.runs[index].finishedAt = Date()
                project.runs[index].error = "Site Audit stopped before this audit finished."
                changed = true
            }
            if changed { try repository.save(project) }
        }
    }

    func projects() throws -> [SEOAuditProjectSummary] {
        try repository.loadSummaries()
    }

    func project(_ id: UUID) throws -> SEOAuditProject {
        do { return try repository.loadProject(id: id) } catch {
            throw SEOAuditInputError("No site audit project \(id.uuidString).")
        }
    }

    func create(_ project: SEOAuditProject) throws -> SEOAuditProject {
        guard !(try repository.loadSummaries()).contains(where: { $0.id == project.id }),
            project.runs.isEmpty
        else {
            throw SEOAuditInputError("This project already exists or contains audit history.")
        }
        try repository.save(project)
        return project
    }

    func rename(_ id: UUID, name raw: String) throws -> SEOAuditProject {
        try requireIdle(id)
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SEOAuditInputError("Enter a project name.") }
        var project = try project(id)
        project.name = String(name.prefix(200))
        project.updatedAt = Date()
        try repository.save(project)
        return project
    }

    func delete(_ id: UUID) throws {
        try requireIdle(id)
        _ = try project(id)
        try repository.delete(id: id)
    }

    func draft(_ id: UUID) throws -> SEOAuditDraft {
        _ = try project(id)
        return try repository.loadDraft(id: id)
    }

    func setDraft(_ id: UUID, _ draft: SEOAuditDraft) throws -> SEOAuditDraft {
        _ = try project(id)
        try repository.saveDraft(id: id, draft)
        return draft
    }

    func updateDraft(_ id: UUID, _ change: (inout SEOAuditDraft) throws -> Void) throws
        -> SEOAuditDraft
    {
        var draft = try draft(id)
        try change(&draft)
        try repository.saveDraft(id: id, draft)
        return draft
    }

    func isActive(_ id: UUID) -> Bool { active.contains(id) }

    private func requireIdle(_ id: UUID) throws {
        guard !active.contains(id) else {
            throw SEOAuditInputError(
                "Wait for this project's audit to finish or cancel it first.")
        }
    }

    func discover(_ url: URL) async throws -> [URL] {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw SEOAuditInputError("Site audits require an HTTP or HTTPS URL.")
        }
        return try await crawler.pages(startingAt: url)
    }

    func run(
        _ request: SEOAuditTaskRequest, scoresOnly: Bool = false,
        progress: @escaping @Sendable (SEOAuditProgress) -> Void = { _ in }
    ) async throws -> SEOAuditProject {
        guard !request.urls.isEmpty, request.urls.count <= Self.maximumPages,
            request.urls.allSatisfy({ ["http", "https"].contains($0.scheme?.lowercased()) })
        else { throw SEOAuditInputError("Select between 1 and 1,000 web pages.") }
        guard active.insert(request.projectID).inserted else {
            throw SEOAuditInputError("This project already has a running audit.")
        }
        defer { active.remove(request.projectID) }
        var project = try project(request.projectID)
        if !scoresOnly {
            guard !project.runs.contains(where: { $0.id == request.runID }) else {
                throw SEOAuditInputError("This audit run already exists.")
            }
            project.runs.insert(SEOAuditRun(id: request.runID), at: 0)
        }
        guard let runIndex = project.runs.firstIndex(where: { $0.id == request.runID }) else {
            throw SEOAuditInputError("The selected audit run no longer exists.")
        }
        if !scoresOnly {
            project.runs[runIndex].discoveredPageCount = request.urls.count
            project.runs[runIndex].state = .running
        }
        try repository.save(project)
        progress(
            SEOAuditProgress(
                project: project, runID: request.runID, completed: 0,
                total: request.urls.count, url: "Starting audit"))
        let auditor = auditor
        let lighthouse = lighthouse
        let images = images
        let projectID = project.id
        let runStartedAt = project.runs[runIndex].startedAt
        let originalPages = project.runs[runIndex].pages
        do {
            try await withThrowingTaskGroup(of: SEOAuditPageResult.self) { group in
                var next = 0
                func schedule(_ index: Int) {
                    let url = request.urls[index]
                    let original = originalPages.first { $0.url == url.absoluteString }
                    group.addTask {
                        try Task.checkCancellation()
                        var page: SEOAuditPageResult
                        if scoresOnly, let original {
                            page = original
                        } else {
                            page = await auditor.audit(url)
                        }
                        try Task.checkCancellation()
                        if !scoresOnly {
                            let snapshots = await images.capture(
                                metadata: page.metadata, projectID: projectID,
                                runID: request.runID, runStartedAt: runStartedAt)
                            page = page.with(metadata: page.metadata.withImageSnapshots(snapshots))
                        }
                        if request.lighthouse || scoresOnly {
                            let result = await lighthouse.audit(url)
                            try Task.checkCancellation()
                            page = page.with(scores: result.scores, lighthouseError: result.error)
                        }
                        try Task.checkCancellation()
                        return page
                    }
                }
                let pageLimit = request.lighthouse || scoresOnly ? 1 : Self.siteConcurrency
                let limit = min(pageLimit, request.urls.count)
                while next < limit {
                    schedule(next)
                    next += 1
                }
                var completed = 0
                while let page = try await group.next() {
                    try Task.checkCancellation()
                    if scoresOnly,
                        let index = project.runs[runIndex].pages.firstIndex(where: {
                            $0.url == page.url
                        })
                    {
                        project.runs[runIndex].pages[index] = page
                    } else {
                        project.runs[runIndex].pages.append(page)
                    }
                    if project.imageURL == nil, let image = page.metadata.openGraphImageURL {
                        project.imageURL = image
                        project.imageSnapshotURL = page.metadata.openGraphImageSnapshotURL
                    }
                    completed += 1
                    if next < request.urls.count {
                        schedule(next)
                        next += 1
                    }
                    if completed == 1 || completed.isMultiple(of: 4) {
                        project.updatedAt = Date()
                        try repository.save(project)
                    }
                    progress(
                        SEOAuditProgress(
                            project: project, runID: request.runID, completed: completed,
                            total: request.urls.count, url: page.url))
                }
            }
            if !scoresOnly {
                let order = Dictionary(
                    request.urls.enumerated().map { ($0.element.absoluteString, $0.offset) },
                    uniquingKeysWith: min)
                project.runs[runIndex].pages.sort { (order[$0.url] ?? 0) < (order[$1.url] ?? 0) }
                project.runs[runIndex].state = .completed
                project.runs[runIndex].finishedAt = Date()
            }
            project.updatedAt = Date()
            try repository.save(project)
            return project
        } catch {
            if !scoresOnly {
                let cancelled = error is CancellationError || Task.isCancelled
                project.runs[runIndex].state = cancelled ? .cancelled : .failed
                project.runs[runIndex].error = cancelled ? nil : error.localizedDescription
                project.runs[runIndex].finishedAt = Date()
                project.updatedAt = Date()
                try repository.save(project)
                progress(
                    SEOAuditProgress(
                        project: project, runID: request.runID,
                        completed: project.runs[runIndex].pages.count,
                        total: request.urls.count, url: ""))
            }
            throw error
        }
    }
}
