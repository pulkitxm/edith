import EdithKit
import Foundation

public actor SEOAuditWorkflow {
    private let repository: SEOAuditRepository
    private let crawler: SitemapCrawler
    private let auditor: SEOPageAuditor
    private let lighthouse: LighthouseAuditor
    private let images: SEOAuditImageStore
    private var active: Set<UUID> = []

    public init(
        repository: SEOAuditRepository = SEOAuditRepository(),
        crawler: SitemapCrawler = SitemapCrawler(), auditor: SEOPageAuditor = SEOPageAuditor(),
        lighthouse: LighthouseAuditor = LighthouseAuditor()
    ) {
        self.repository = repository
        self.crawler = crawler
        self.auditor = auditor
        self.lighthouse = lighthouse
        self.images = SEOAuditImageStore(root: repository.root)
    }

    public func register(on tasks: AgentTaskService, runtime: AgentRuntime) async throws {
        try recoverInterruptedRuns()
        for operation in SEOAuditTaskOperation.internalOperations {
            await runtime.register(operation: operation) { payload in
                try await self.perform(operation: operation, payload: payload)
            }
        }
        await tasks.register(operation: SEOAuditTaskOperation.discover) { payload, context in
            let url = try AgentPayload.decode(URL.self, from: payload)
            context.report("Discovering pages")
            return try await AgentPayload.encode(self.discover(url))
        }
        await tasks.register(operation: SEOAuditTaskOperation.audit) { payload, context in
            let request = try AgentPayload.decode(SEOAuditTaskRequest.self, from: payload)
            return try await AgentPayload.encode(self.run(request, context: context))
        }
        await tasks.register(operation: SEOAuditTaskOperation.lighthouse) { payload, context in
            let request = try AgentPayload.decode(SEOAuditTaskRequest.self, from: payload)
            return try await AgentPayload.encode(
                self.run(request, context: context, scoresOnly: true))
        }
    }

    public func recoverInterruptedRuns() throws {
        for summary in try repository.loadSummaries() {
            var project = try repository.loadProject(id: summary.id)
            var changed = false
            for index in project.runs.indices where project.runs[index].state == .running {
                project.runs[index].state = .failed
                project.runs[index].finishedAt = Date()
                project.runs[index].error = "The daemon restarted before this audit finished."
                changed = true
            }
            if changed { try repository.save(project) }
        }
    }

    public func perform(operation: String, payload: Data) throws -> Data {
        switch operation {
        case SEOAuditTaskOperation.projects:
            return try AgentPayload.encode(repository.loadSummaries())
        case SEOAuditTaskOperation.project:
            return try AgentPayload.encode(
                repository.loadProject(
                    id: AgentPayload.decode(UUID.self, from: payload)))
        case SEOAuditTaskOperation.create:
            let project = try AgentPayload.decode(SEOAuditProject.self, from: payload)
            guard !(try repository.loadSummaries()).contains(where: { $0.id == project.id }),
                project.runs.isEmpty
            else {
                throw AgentError(.refused, "This project already exists or contains audit history.")
            }
            try repository.save(project)
            return try AgentPayload.encode(project)
        case SEOAuditTaskOperation.rename:
            let request = try AgentPayload.decode(SEOAuditRenameRequest.self, from: payload)
            try requireIdle(request.id)
            let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw AgentError(.refused, "Enter a project name.") }
            var project = try repository.loadProject(id: request.id)
            project.name = String(name.prefix(200))
            project.updatedAt = Date()
            try repository.save(project)
            return try AgentPayload.encode(project)
        case SEOAuditTaskOperation.delete:
            let id = try AgentPayload.decode(UUID.self, from: payload)
            try requireIdle(id)
            try repository.delete(id: id)
            return Data()
        default:
            throw AgentError(.unknownOperation, "Unknown project operation.")
        }
    }

    private func requireIdle(_ id: UUID) throws {
        guard !active.contains(id) else {
            throw AgentError(
                .refused, "Wait for this project's audit to finish or cancel it first.")
        }
    }

    public func discover(_ url: URL) async throws -> [URL] {
        guard ["http", "https"].contains(url.scheme) else {
            throw AgentError(.refused, "Site audits require an HTTP or HTTPS URL.")
        }
        return try await crawler.pages(startingAt: url)
    }

    public func run(
        _ request: SEOAuditTaskRequest, context: AgentTaskContext, scoresOnly: Bool = false
    ) async throws -> SEOAuditProject {
        guard !request.urls.isEmpty, request.urls.count <= 1_000,
            request.urls.allSatisfy({ ["http", "https"].contains($0.scheme) })
        else { throw AgentError(.refused, "Select between 1 and 1,000 web pages.") }
        guard active.insert(request.projectID).inserted else {
            throw AgentError(.refused, "This project already has a running audit.")
        }
        defer { active.remove(request.projectID) }
        var project = try repository.loadProject(id: request.projectID)
        if !scoresOnly {
            guard !project.runs.contains(where: { $0.id == request.runID }) else {
                throw AgentError(.refused, "This audit run already exists.")
            }
            project.runs.insert(SEOAuditRun(id: request.runID), at: 0)
        }
        guard let runIndex = project.runs.firstIndex(where: { $0.id == request.runID }) else {
            throw AgentError(.refused, "The selected audit run no longer exists.")
        }
        if !scoresOnly {
            project.runs[runIndex].discoveredPageCount = request.urls.count
            project.runs[runIndex].state = .running
        }
        try repository.save(project)
        let auditor = auditor
        let lighthouse = lighthouse
        let images = images
        let projectID = project.id
        let runStartedAt = project.runs[runIndex].startedAt
        let originalPages = project.runs[runIndex].pages
        do {
            try await withThrowingTaskGroup(of: (Int, SEOAuditPageResult).self) { group in
                var next = 0
                func schedule(_ index: Int) {
                    let url = request.urls[index]
                    let original = originalPages.first {
                        $0.url == url.absoluteString
                    }
                    group.addTask {
                        try Task.checkCancellation()
                        var page: SEOAuditPageResult
                        if scoresOnly, let original {
                            page = original
                        } else {
                            page = await auditor.audit(url)
                        }
                        if !scoresOnly {
                            let snapshots = await images.capture(
                                metadata: page.metadata, projectID: projectID, runID: request.runID,
                                runStartedAt: runStartedAt)
                            page = page.with(metadata: page.metadata.withImageSnapshots(snapshots))
                        }
                        if request.lighthouse || scoresOnly {
                            let result = await lighthouse.audit(url)
                            page = page.with(scores: result.scores, lighthouseError: result.error)
                        }
                        try Task.checkCancellation()
                        return (index, page)
                    }
                }
                let limit = min(SiteAuditConcurrency.limit, request.urls.count)
                while next < limit { schedule(next); next += 1 }
                var completed = 0
                while let (_, page) = try await group.next() {
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
                    project.updatedAt = Date()
                    try repository.save(project)
                    completed += 1
                    context.report("Audited \(completed) of \(request.urls.count): \(page.url)")
                    if next < request.urls.count { schedule(next); next += 1 }
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
                project.runs[runIndex].state = error is CancellationError ? .cancelled : .failed
                project.runs[runIndex].error =
                    error is CancellationError ? nil : error.localizedDescription
                project.runs[runIndex].finishedAt = Date()
                try repository.save(project)
            }
            throw error
        }
    }
}
