import Foundation
import Testing
@testable import SEOAuditExtension

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
