import Foundation
import Testing

@testable import Edith

@Suite struct SEOAuditTests {
    @Test func localInputUsesHTTPAndKeepsThePort() throws {
        let url = try #require(SEOAuditURLInput.normalize("localhost:3000"))
        #expect(url.absoluteString == "http://localhost:3000")
        #expect(SEOAuditURLInput.projectName(for: url) == "localhost:3000")
    }

    @Test func publicInputUsesHTTPS() throws {
        let url = try #require(SEOAuditURLInput.normalize("www.example.com/docs"))
        #expect(url.absoluteString == "https://www.example.com/docs")
        #expect(SEOAuditURLInput.projectName(for: url) == "example.com")
    }

    @Test func metadataParserReadsSearchAndSocialFields() {
        let html = """
            <html lang="en"><head>
            <title>Example audit page with a useful search title</title>
            <meta name="description" content="A complete description for the page that gives searchers enough context before they choose to visit the result.">
            <meta property="og:title" content="Social title">
            <meta property="og:description" content="Social description">
            <meta property="og:image" content="/social.png">
            <meta property="og:type" content="website">
            <meta name="twitter:card" content="summary_large_image">
            <link rel="canonical" href="/preferred">
            </head><body><h1>Page heading</h1><p>one two three</p></body></html>
            """
        let metadata = HTMLMetadataParser.parse(
            html, baseURL: URL(string: "https://example.com/docs/page")!)

        #expect(metadata.language == "en")
        #expect(metadata.heading == "Page heading")
        #expect(metadata.openGraphTitle == "Social title")
        #expect(metadata.openGraphImageURL == "https://example.com/social.png")
        #expect(metadata.canonicalURL == "https://example.com/preferred")
        #expect(metadata.twitterCard == "summary_large_image")
        #expect(metadata.wordCount == 5)
    }

    @Test func issueAnalyzerFindsMissingEssentials() {
        let issues = SEOIssueAnalyzer.issues(
            url: URL(string: "http://example.com")!, statusCode: 404, metadata: .empty)
        let codes = Set(issues.map(\.code))

        #expect(codes.contains("http-status"))
        #expect(codes.contains("title-missing"))
        #expect(codes.contains("description-missing"))
        #expect(codes.contains("canonical-missing"))
        #expect(codes.contains("open-graph-image"))
        #expect(codes.contains("https"))
    }

    @Test func repositoryStoresProjectsSeparatelyFromTheIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        var project = SEOAuditProject(name: "Example", baseURL: "https://example.com")
        project.runs = [SEOAuditRun(state: .completed, discoveredPageCount: 1)]

        try repository.save(project)
        let summaries = try repository.loadSummaries()
        let restored = try repository.loadProject(id: project.id)

        #expect(summaries.map(\.id) == [project.id])
        #expect(summaries[0].name == "Example")
        #expect(restored.id == project.id)
        #expect(restored.name == project.name)
        #expect(restored.baseURL == project.baseURL)
        #expect(restored.runs.map(\.id) == project.runs.map(\.id))
    }

    @Test func pageHistoryExcludesTheSelectedRunAndOrdersNewestFirst() {
        let url = "https://example.com/page"
        let olderPage = page(url: url, date: Date(timeIntervalSince1970: 100))
        let newerPage = page(url: url, date: Date(timeIntervalSince1970: 200))
        let currentPage = page(url: url, date: Date(timeIntervalSince1970: 300))
        let oldRun = SEOAuditRun(
            startedAt: olderPage.auditedAt, state: .completed, pages: [olderPage])
        let newRun = SEOAuditRun(
            startedAt: newerPage.auditedAt, state: .completed, pages: [newerPage])
        let currentRun = SEOAuditRun(
            startedAt: currentPage.auditedAt, state: .completed, pages: [currentPage])
        let project = SEOAuditProject(
            name: "Example", baseURL: "https://example.com",
            runs: [oldRun, currentRun, newRun])

        #expect(project.history(for: url, excluding: currentRun.id) == [newerPage, olderPage])
    }

    @Test @MainActor func pageSelectionSupportsBulkAndIndividualChanges() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SEOAuditModel(repository: SEOAuditRepository(root: root))
        model.discoveredPageURLs = [
            "https://example.com/", "https://example.com/docs", "https://example.com/about",
        ]

        model.selectAllPages()
        #expect(model.selectedPageCount == 3)
        model.togglePage("https://example.com/docs")
        #expect(model.selectedPageCount == 2)
        model.deselectAllPages()
        #expect(model.selectedPageCount == 0)
    }

    @Test @MainActor func projectManagementRenamesAndDeletesStoredProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        let project = SEOAuditProject(name: "Before", baseURL: "https://example.com")
        try repository.save(project)
        let model = SEOAuditModel(repository: repository)

        model.renameProject(id: project.id, to: "After")
        #expect(model.projects.first?.name == "After")
        #expect(try repository.loadProject(id: project.id).name == "After")

        model.deleteProject(id: project.id)
        #expect(model.projects.isEmpty)
        #expect(try repository.loadSummaries().isEmpty)
    }

    @Test func projectCardsStayStationaryAndOfferBothActionMenus() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/Edith/Features/SEOAudit/Views/SEOAuditPage.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "private struct SEOAuditProjectCard"))
        let end = try #require(
            source.range(
                of: "private struct SEOAuditRenameProjectSheet",
                range: start.upperBound..<source.endIndex))
        let card = source[start.lowerBound..<end.lowerBound]

        #expect(!card.contains(".scaleEffect("))
        #expect(card.contains("Menu {"))
        #expect(card.contains(".contextMenu { projectActions }"))
        #expect(card.contains("Label(\"View details\""))
        #expect(card.contains("Label(\"Rename\""))
        #expect(card.contains("Label(\"Delete\""))
    }

    @Test func lighthouseResultReplacesAnEarlierFailure() {
        let unavailable = SEOAuditIssue(
            code: "lighthouse-unavailable", severity: .notice,
            title: "Lighthouse did not finish", detail: "Not installed")
        let original = SEOAuditPageResult(
            url: "https://example.com", statusCode: 200, responseMilliseconds: 20, bytes: 100,
            metadata: .empty, issues: [unavailable])
        let updated = original.with(
            scores: SEOAuditScores(
                performance: 91, accessibility: 92, bestPractices: 93, seo: 94),
            lighthouseError: nil)

        #expect(updated.hasLighthouseScores)
        #expect(updated.scores.average == 92)
        #expect(!updated.issues.contains { $0.code == "lighthouse-unavailable" })
    }

    @Test func projectViewDoesNotForceUnwrapNavigationState() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/Edith/Features/SEOAudit/Views/SEOAuditProjectView.swift"),
            encoding: .utf8)

        #expect(!source.contains("selectedProject!"))
    }

    @Test func projectBackButtonUsesAStationaryHoverSurface() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/Edith/Features/SEOAudit/Views/SEOAuditProjectView.swift"),
            encoding: .utf8)

        #expect(source.contains("@State private var backHovered = false"))
        #expect(source.contains("backHovered ? DashSkin.paper2(dark) : .clear"))
        #expect(source.contains("backHovered ? DashSkin.accent(dark).opacity(0.45) : .clear"))
        #expect(!source.contains("backHovered ? 1."))
    }

    private func page(url: String, date: Date) -> SEOAuditPageResult {
        SEOAuditPageResult(
            url: url, auditedAt: date, statusCode: 200, responseMilliseconds: 20, bytes: 100,
            metadata: .empty, issues: [])
    }
}
