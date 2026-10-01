import Foundation
import Testing

@testable import EdithAgent
@testable import EdithCLI
@testable import EdithKit

@Suite struct SEOAuditSelectionTests {
    @Test func createUsesTheHostWhenTheNameIsBlank() throws {
        let project = try SEOAuditSelection.makeProject(url: "example.com/docs", name: "  ")
        #expect(project.name == "example.com")
        #expect(project.baseURL == "https://example.com/docs")
        #expect(project.runs.isEmpty)
    }

    @Test func discoverySelectsOnlyNewPages() {
        let merged = SEOAuditSelection.mergeDiscovery(
            discovered: ["https://example.com/a"],
            selected: ["https://example.com/a"],
            found: ["https://example.com/a", "https://example.com/b"])
        #expect(merged.discovered == ["https://example.com/a", "https://example.com/b"])
        #expect(merged.selected == ["https://example.com/a", "https://example.com/b"])
    }

    @Test func chooseRejectsPagesThatWereNotDiscovered() {
        #expect(throws: SEOAuditInputError.self) {
            try SEOAuditSelection.choose(
                discovered: ["https://example.com/a"], selected: [],
                edit: .only(["https://example.com/missing"]))
        }
    }

    @Test func filtersAndRunOffsetsMatchTheProjectScreen() {
        let older = SEOAuditRun(
            startedAt: Date(timeIntervalSince1970: 10), state: .completed,
            pages: [page("https://example.com/old", severity: .notice)])
        let newer = SEOAuditRun(
            startedAt: Date(timeIntervalSince1970: 20), state: .completed,
            pages: [
                page("https://example.com/new", severity: .error),
                page("https://example.com/ok", severity: .warning),
            ])
        let project = SEOAuditProject(
            name: "Example", baseURL: "https://example.com", runs: [older, newer])
        #expect(SEOAuditSelection.run(in: project, id: nil, offset: 0)?.id == newer.id)
        #expect(SEOAuditSelection.run(in: project, id: older.id, offset: 0)?.id == older.id)
        let errors = SEOAuditSelection.matching(newer.pages, query: "", severity: .error)
        #expect(errors.map(\.url) == ["https://example.com/new"])
        let titled = SEOAuditSelection.matching(newer.pages, query: "ok", severity: nil)
        #expect(titled.map(\.url) == ["https://example.com/ok"])
    }

    private func page(_ url: String, severity: SEOAuditSeverity) -> SEOAuditPageResult {
        SEOAuditPageResult(
            url: url, statusCode: 200, responseMilliseconds: 1, bytes: 10,
            metadata: SEOAuditMetadata(
                title: url, description: nil, canonicalURL: nil, robots: nil, language: nil,
                heading: nil, openGraphTitle: nil, openGraphDescription: nil,
                openGraphImageURL: nil, openGraphImageSnapshotURL: nil, openGraphType: nil,
                twitterCard: nil, twitterTitle: nil, twitterDescription: nil, twitterImageURL: nil,
                twitterImageSnapshotURL: nil, wordCount: 1),
            issues: [
                SEOAuditIssue(code: "sample", severity: severity, title: "Sample", detail: "Detail")
            ])
    }
}

@Suite struct SEOAuditControllerTests {
    @Test func startSubmitsOnlyTheSelectedPages() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let project = try await harness.controller.create(
            url: "https://example.com", name: "Example")
        var draft = SEOAuditDraft(
            discoveredPageURLs: ["https://example.com/", "https://example.com/a"],
            selectedPageURLs: ["https://example.com/a"], includeLighthouse: false)
        _ = try await harness.client.setDraft(project.id, draft)
        let launch = try await harness.controller.start(project.id, lighthouse: nil, wait: false)
        #expect(launch.request.urls.map(\.absoluteString) == ["https://example.com/a"])
        #expect(launch.request.lighthouse == false)
        #expect(launch.snapshot?.state == .queued)
        draft = try await harness.client.draft(project.id)
        #expect(draft.activeTaskIDs == [launch.request.runID])
    }

    @Test func stopCancelsTheRecordedTask() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let project = try await harness.controller.create(
            url: "https://example.com", name: "Example")
        let taskID = UUID()
        _ = try await harness.client.setDraft(
            project.id, SEOAuditDraft(activeTaskIDs: [taskID]))
        let cancelled = try await harness.controller.stop(project.id)
        #expect(cancelled == [taskID])
        let draft = try await harness.client.draft(project.id)
        #expect(draft.activeTaskIDs.isEmpty)
    }

    private final class Harness: @unchecked Sendable {
        let root: URL
        let client: SEOAuditProjectClient
        let controller: SEOAuditController
        private let cancelled = LockedIDs()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let repository = SEOAuditRepository(root: root)
            let workflow = SEOAuditWorkflow(repository: repository)
            client = SEOAuditProjectClient { operation, payload in
                try await workflow.perform(operation: operation, payload: payload)
            }
            let cancelled = cancelled
            controller = SEOAuditController(
                projects: client,
                submitTask: { submission in
                    AgentTaskSnapshot(
                        id: submission.id, operation: submission.operation, title: submission.title,
                        state: .queued)
                },
                runTask: { _ in
                    try AgentPayload.encode([URL(string: "https://example.com/a")!])
                },
                cancelTask: { id in
                    cancelled.values.append(id)
                    return AgentTaskSnapshot(
                        id: id, operation: SEOAuditTaskOperation.audit, title: "Audit",
                        state: .cancelled)
                })
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class LockedIDs: @unchecked Sendable {
    var values: [UUID] = []
}

@Suite struct SEOAuditCLITests {
    @Test func commandsParseAndJSONShapesStayStable() throws {
        #expect(try EdRoot.parseAsRoot(["seo"]) is SEOListCommand)
        #expect(try EdRoot.parseAsRoot(["seo", "list"]) is SEOListCommand)
        let pages = try #require(
            try EdRoot.parseAsRoot([
                "seo", "pages", "00000000-0000-0000-0000-000000000000", "--only",
                "https://example.com/a", "--refresh",
            ]) as? SEOPagesCommand)
        #expect(pages.only == ["https://example.com/a"])
        #expect(pages.refresh)
        let start = try #require(
            try EdRoot.parseAsRoot([
                "seo", "start", "00000000-0000-0000-0000-000000000000", "--no-lighthouse",
                "--wait",
            ]) as? SEOStartCommand)
        #expect(start.noLighthouse)
        #expect(start.wait)

        let summary = SEOCLI.summary(
            SEOAuditProjectSummary(
                project: SEOAuditProject(name: "Example", baseURL: "https://example.com")))
        guard case let .object(fields) = summary else {
            Issue.record("summary was not an object")
            return
        }
        #expect(
            Set(fields.keys) == ["id", "name", "baseURL", "updatedAt", "latestRun"])
        let help = SEOListCommand.helpMessage(columns: 200)
        #expect(help.contains("ed seo ls --json"))
        #expect(help.contains("Emit JSON"))
    }
}
