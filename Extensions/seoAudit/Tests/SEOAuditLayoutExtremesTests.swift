import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import SEOAuditExtension

@MainActor @Suite(.serialized) struct SEOAuditLayoutExtremesTests {
    private static let page = SEOAuditPageResult(
        url: "https://synthetic.example.invalid/docs", statusCode: 200,
        responseMilliseconds: 20, bytes: 2_048, metadata: .empty,
        issues: [
            .init(
                code: "title", severity: .error, title: "Missing title",
                detail: "Add a descriptive title.")
        ])

    private static func accordion() -> some View {
        SEOAuditPageAccordion(
            page: page, history: [], selected: .constant(true), lighthouseAvailable: true,
            lighthouseRunning: false, runLighthouse: {}, socialPlatform: .facebook,
            expanded: .constant(true))
    }

    private static func fittingSize(_ view: some View, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func expandedPageRowLaysOutUnderUnboundedAndDegenerateWidths() {
        let shapes: [AnyView] = [
            AnyView(Grid { GridRow { Self.accordion() } }),
            AnyView(ScrollView(.horizontal) { LazyHStack { Self.accordion() } }),
            AnyView(ScrollView(.horizontal) { HStack { Self.accordion() } }),
            AnyView(Self.accordion().fixedSize()),
            AnyView(Self.accordion().frame(width: 0)),
            AnyView(Self.accordion().frame(width: 0.5)),
            AnyView(Self.accordion().frame(width: 24)),
        ]
        for (index, shape) in shapes.enumerated() {
            for width in [1.0, 360, 1100] {
                let size = Self.fittingSize(shape, width: width)
                #expect(size.width.isFinite && size.height.isFinite, "shape \(index) at \(width)")
            }
        }
    }

    @Test func projectSummaryLaysOutUnderUnboundedAndDegenerateWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = SEOAuditProject(
            name: "Synthetic site", baseURL: "https://synthetic.example.invalid",
            runs: [.init(state: .completed, discoveredPageCount: 1, pages: [Self.page])])
        try SEOAuditRepository(root: root).save(project)
        let service = SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root),
                lighthouse: LighthouseAuditor(locate: { nil })))
        let model = SEOAuditModel(service: service)
        await model.refreshProjects()
        await model.selectProject(id: project.id)
        let shapes: [AnyView] = [
            AnyView(Grid { GridRow { SEOAuditPage(model: model) } }),
            AnyView(ScrollView(.horizontal) { LazyHStack { SEOAuditPage(model: model) } }),
            AnyView(SEOAuditPage(model: model).frame(width: 0, height: 600)),
            AnyView(SEOAuditPage(model: model).frame(width: 1, height: 600)),
        ]
        for (index, shape) in shapes.enumerated() {
            for width in [1.0, 360, 1100] {
                let size = Self.fittingSize(shape, width: width)
                #expect(size.width.isFinite && size.height.isFinite, "shape \(index) at \(width)")
            }
        }
        model.shutdown()
        await service.shutdown()
    }
}
