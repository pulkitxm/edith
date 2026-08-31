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
            <meta name="twitter:title" content="X title">
            <meta name="twitter:description" content="X description">
            <meta name="twitter:image" content="/x-social.png">
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
        #expect(metadata.twitterTitle == "X title")
        #expect(metadata.twitterDescription == "X description")
        #expect(metadata.twitterImageURL == "https://example.com/x-social.png")
        #expect(metadata.openGraphImageSnapshotURL == nil)
        #expect(metadata.twitterImageSnapshotURL == nil)
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
        var project = SEOAuditProject(
            name: "Example", baseURL: "https://example.com",
            imageSnapshotURL: "file:///tmp/example.png")
        project.runs = [SEOAuditRun(state: .completed, discoveredPageCount: 1)]

        try repository.save(project)
        let summaries = try repository.loadSummaries()
        let restored = try repository.loadProject(id: project.id)

        #expect(summaries.map(\.id) == [project.id])
        #expect(summaries[0].name == "Example")
        #expect(restored.id == project.id)
        #expect(restored.name == project.name)
        #expect(restored.baseURL == project.baseURL)
        #expect(restored.imageSnapshotURL == project.imageSnapshotURL)
        #expect(restored.runs.map(\.id) == project.runs.map(\.id))
    }

    @Test func imageSnapshotsStayAttachedToTimestampedRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SEOAuditImageURLProtocol.self]
        let store = SEOAuditImageStore(
            root: root, session: URLSession(configuration: configuration))
        let projectID = UUID()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = HTMLMetadataParser.parse(
            """
            <meta property="og:image" content="https://example.com/social.png">
            <meta name="twitter:image" content="https://example.com/social.png">
            """, baseURL: URL(string: "https://example.com")!)

        let snapshots = await store.capture(
            metadata: metadata, projectID: projectID, runID: runID, runStartedAt: startedAt)
        let openGraphURL = try #require(snapshots.openGraphImageURL.flatMap(URL.init(string:)))
        let nextRunID = UUID()
        let nextRunSnapshots = await store.capture(
            metadata: metadata, projectID: projectID, runID: nextRunID,
            runStartedAt: startedAt.addingTimeInterval(100))

        #expect(openGraphURL.isFileURL)
        #expect(FileManager.default.fileExists(atPath: openGraphURL.path))
        #expect(openGraphURL.path.contains("1700000000-\(runID.uuidString.lowercased())"))
        #expect(snapshots.twitterImageURL == snapshots.openGraphImageURL)
        #expect(nextRunSnapshots.openGraphImageURL != snapshots.openGraphImageURL)
        #expect(nextRunSnapshots.openGraphImageURL?.contains("1700000100-") == true)
    }

    @Test func deletingAProjectRemovesItsImageSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        let project = SEOAuditProject(name: "Example", baseURL: "https://example.com")
        try repository.save(project)
        let assets = root.appendingPathComponent("assets")
            .appendingPathComponent(project.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([1]).write(to: assets.appendingPathComponent("snapshot.png"))

        try repository.delete(id: project.id)

        #expect(!FileManager.default.fileExists(atPath: assets.path))
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

    @Test func projectCardsExposeLiveAuditProgress() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/Edith/Features/SEOAudit/Views/SEOAuditPage.swift"),
            encoding: .utf8)

        #expect(source.contains("activeRun: active ? model.selectedRun : nil"))
        #expect(source.contains("AUDITING \\(current)/\\(total)"))
        #expect(source.contains("Text(activeProgress, format: .percent"))
        #expect(source.contains("geometry.size.width * activeProgress"))
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

    @Test @MainActor func navigationUsesTheAppLifetimeAuditModel() throws {
        #expect(SEOAuditModel.shared === SEOAuditModel.shared)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/Edith/Features/SEOAudit/Views/SEOAuditPage.swift"),
            encoding: .utf8)

        #expect(source.contains("@State private var model = SEOAuditModel.shared"))
        #expect(!source.contains("State(initialValue: SEOAuditModel())"))
    }

    @Test @MainActor func backNavigationKeepsTheActiveAuditAttached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        let active = SEOAuditProject(name: "Active", baseURL: "https://active.example")
        let other = SEOAuditProject(name: "Other", baseURL: "https://other.example")
        try repository.save(active)
        try repository.save(other)
        let model = SEOAuditModel(repository: repository)

        model.selectProject(id: active.id)
        model.stage = .auditing(current: 2, total: 55, url: "https://active.example/two")
        model.closeProject()

        #expect(!model.projectDetailPresented)
        #expect(model.selectedProject?.id == active.id)
        #expect(model.isRunning)

        model.selectProject(id: other.id)
        #expect(model.selectedProject?.id == active.id)
        #expect(!model.projectDetailPresented)

        model.selectProject(id: active.id)
        #expect(model.projectDetailPresented)
        #expect(model.selectedProject?.id == active.id)
    }

    @Test func socialPreviewsExposePlatformSpecificFormats() throws {
        #expect(
            SEOAuditSocialPlatform.allCases.map(\.title) == [
                "Facebook", "X", "LinkedIn", "Slack", "Discord",
            ])
        #expect(SEOAuditSocialPlatform.facebook.formatLabel.contains("1200×630"))
        #expect(SEOAuditSocialPlatform.x.formatLabel.contains("large card"))
        #expect(SEOAuditSocialPlatform.linkedIn.formatLabel.contains("1200×627"))

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/Edith/Features/SEOAudit/Views/SEOAuditPageAccordion.swift"),
            encoding: .utf8)

        #expect(source.contains("usesXSummaryCard"))
        #expect(source.contains("1:1 · summary"))
        #expect(source.contains("twitterImageURL ?? page.metadata.openGraphImageURL"))
    }

    private func page(url: String, date: Date) -> SEOAuditPageResult {
        SEOAuditPageResult(
            url: url, auditedAt: date, statusCode: 200, responseMilliseconds: 20, bytes: 100,
            metadata: .empty, issues: [])
    }
}

private final class SEOAuditImageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4E, 0x47]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
