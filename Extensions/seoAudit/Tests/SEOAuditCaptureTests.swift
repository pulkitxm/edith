import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import SEOAuditExtension

@MainActor @Suite(.serialized) struct SEOAuditCaptureTests {
    private func model(projects: [SEOAuditProject], root: URL) throws -> (
        SEOAuditModel, SEOAuditService
    ) {
        for project in projects { try SEOAuditRepository(root: root).save(project) }
        let service = SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root),
                lighthouse: LighthouseAuditor(locate: { nil })))
        return (SEOAuditModel(service: service), service)
    }

    private static var pages: [SEOAuditPageResult] {
        ["/", "/docs", "/pricing", "/blog/launch"].enumerated().map { index, path in
            SEOAuditPageResult(
                url: "https://synthetic.example.invalid\(path)", statusCode: 200,
                responseMilliseconds: 40 + index * 25, bytes: 2_048, metadata: .empty,
                issues: index == 2
                    ? []
                    : [
                        .init(
                            code: "title", severity: .error, title: "Missing title",
                            detail: "Add a descriptive title."),
                        .init(
                            code: "description", severity: .warning,
                            title: "Short description",
                            detail: "Aim for about 150 characters."),
                    ])
        }
    }

    @Test func projectsListAndDetailRenderEveryVariant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audited = SEOAuditProject(
            name: "Synthetic site", baseURL: "https://synthetic.example.invalid",
            runs: [.init(state: .completed, discoveredPageCount: 4, pages: Self.pages)])
        let fresh = SEOAuditProject(name: "Docs preview", baseURL: "https://docs.example.invalid")
        let (model, service) = try model(projects: [audited, fresh], root: root)
        await model.refreshProjects()
        for variant in SEOAuditRenderCapture.variants {
            model.closeProject()
            let bitmap = try await SEOAuditRenderCapture.render("seo-projects", variant: variant) {
                SEOAuditPage(model: model)
            }
            #expect(SEOAuditRenderCapture.distinctColors(bitmap) > 3)
            await model.selectProject(id: audited.id)
            try await SEOAuditRenderCapture.render("seo-detail", variant: variant) {
                SEOAuditPage(model: model)
            }
            await model.selectProject(id: fresh.id)
            try await SEOAuditRenderCapture.render("seo-detail-first-run", variant: variant) {
                SEOAuditPage(model: model)
            }
        }
        model.shutdown()
        await service.shutdown()
    }

    @Test func expandedPageRowRenders() async throws {
        let page = try #require(Self.pages.first)
        for variant in [SEOAuditRenderCapture.variants[0], SEOAuditRenderCapture.variants[3]] {
            try await SEOAuditRenderCapture.render("seo-page-expanded", variant: variant) {
                ScrollView {
                    SEOAuditPageAccordion(
                        page: page, history: [], selected: .constant(true),
                        lighthouseAvailable: true, lighthouseRunning: false, runLighthouse: {},
                        socialPlatform: .facebook, expanded: .constant(true)
                    )
                    .padding(UIScale.pt(24))
                }
                .background(DashSkin.paper(variant.scheme == .dark))
            }
        }
    }

    @Test func firstRunLoadingAndErrorStatesRender() async throws {
        for variant in SEOAuditRenderCapture.variants {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (empty, emptyService) = try model(projects: [], root: root)
            await empty.refreshProjects()
            try await SEOAuditRenderCapture.render("seo-first-run", variant: variant) {
                SEOAuditPage(model: empty)
            }
            empty.shutdown()
            await emptyService.shutdown()

            let (loading, loadingService) = try model(projects: [], root: root)
            _ = loading.projectsLoad.begin()
            try await SEOAuditRenderCapture.render("seo-loading", variant: variant) {
                SEOAuditPage(model: loading)
            }
            loading.shutdown()
            await loadingService.shutdown()

            let (failing, failingService) = try model(projects: [], root: root)
            let request = failing.projectsLoad.begin()
            failing.projectsLoad.fail(request, message: "Saved projects could not be read.")
            try await SEOAuditRenderCapture.render("seo-error", variant: variant) {
                SEOAuditPage(model: failing)
            }
            failing.shutdown()
            await failingService.shutdown()
        }
    }
}
