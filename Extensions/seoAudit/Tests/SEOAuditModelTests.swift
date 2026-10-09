import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import SEOAuditExtension

@Suite(.serialized) @MainActor struct SEOAuditModelTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func service(_ root: URL) -> SEOAuditService {
        SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root),
                lighthouse: LighthouseAuditor(locate: { nil })))
    }
    @Test func pageIndexFiltersOffMainAndCollapsesKeystrokes() async throws {
        let model = SEOAuditModel(service: service(root()))
        let thread = SEOThreadFlag()
        SEOPageIndex.recordThread = { thread.main = Thread.isMainThread }
        defer { SEOPageIndex.recordThread = nil }
        let project = seoProject(pages: 1_000)
        await model.open(project)
        let builds = model.indexBuildCount
        #expect(thread.main == false)
        #expect(model.visiblePages.count == 1_000)
        let target = "https://example.test/p/12/end"
        #expect(model.historyByURL[target]?.count == 2)
        #expect(
            model.historyByURL[target]?.map(\.auditedAt) == [
                Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 100),
            ])

        model.query = "p/1"
        model.query = "p/12"
        model.query = target
        #expect(model.completedFilters.isEmpty)
        #expect(model.indexBuildCount == builds)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.completedFilters == [target])
        #expect(model.visiblePages.map(\.url) == [target])
        #expect(model.indexBuildCount == builds)

        model.severity = .error
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.completedFilters == [target, target])
        #expect(model.visiblePages.map(\.url) == [target])
        #expect(model.indexBuildCount == builds)
    }
    @Test @MainActor func pageSelectionSupportsBulkAndIndividualChanges() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SEOAuditModel(service: service(root))
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
    @Test @MainActor func projectManagementRenamesAndDeletesStoredProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        let project = SEOAuditProject(name: "Before", baseURL: "https://example.com")
        try repository.save(project)
        let model = SEOAuditModel(service: service(root))

        await model.renameProject(id: project.id, to: "After")
        #expect(model.projects.first?.name == "After")
        #expect(try repository.loadProject(id: project.id).name == "After")

        await model.deleteProject(id: project.id)
        #expect(model.projects.isEmpty)
        #expect(try repository.loadSummaries().isEmpty)
    }
    @Test @MainActor func backNavigationKeepsTheActiveAuditAttached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root)
        let active = SEOAuditProject(name: "Active", baseURL: "https://active.example")
        let other = SEOAuditProject(name: "Other", baseURL: "https://other.example")
        try repository.save(active)
        try repository.save(other)
        let model = SEOAuditModel(service: service(root))

        await model.selectProject(id: active.id)
        model.stage = .auditing(current: 2, total: 55, url: "https://active.example/two")
        model.closeProject()

        #expect(!model.projectDetailPresented)
        #expect(model.selectedProject?.id == active.id)
        #expect(model.isRunning)

        await model.selectProject(id: other.id)
        #expect(model.selectedProject?.id == active.id)
        #expect(!model.projectDetailPresented)

        await model.selectProject(id: active.id)
        #expect(model.projectDetailPresented)
        #expect(model.selectedProject?.id == active.id)
    }
}
private final class SEOThreadFlag: @unchecked Sendable {
    var main = true
}

private func seoProject(pages: Int) -> SEOAuditProject {
    func rows(_ stamp: TimeInterval, issues: Bool) -> [SEOAuditPageResult] {
        (0..<pages).map { index in
            let url = "https://example.test/p/\(index)/end"
            let pageIssues =
                issues && index == 12
                ? [
                    SEOAuditIssue(
                        code: "title", severity: .error, title: "Missing", detail: "Add one")
                ]
                : []
            return SEOAuditPageResult(
                url: url, auditedAt: Date(timeIntervalSince1970: stamp), statusCode: 200,
                responseMilliseconds: 20, bytes: 128, metadata: .empty, issues: pageIssues)
        }
    }
    var project = SEOAuditProject(name: "Example", baseURL: "https://example.test")
    project.runs = [
        SEOAuditRun(
            startedAt: Date(timeIntervalSince1970: 300), state: .completed,
            discoveredPageCount: pages, pages: rows(300, issues: true)),
        SEOAuditRun(
            startedAt: Date(timeIntervalSince1970: 200), state: .completed,
            discoveredPageCount: pages, pages: rows(200, issues: false)),
        SEOAuditRun(
            startedAt: Date(timeIntervalSince1970: 100), state: .completed,
            discoveredPageCount: pages, pages: rows(100, issues: false)),
    ]
    return project
}
