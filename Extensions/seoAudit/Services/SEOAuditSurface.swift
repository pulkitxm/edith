import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class SEOAuditSurface {
    private let service: SEOAuditService
    private let privacy: @MainActor () -> [String: String]

    init(
        service: SEOAuditService,
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) { self.service = service; self.privacy = privacy }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "seoAudit", command: command, payload: payload,
            snapshot: { [weak self] tile in
                guard let self else { throw ExtensionPeerError.unavailable }
                return try await self.snapshot(tile)
            },
            perform: { _ in throw ExtensionPeerError.invalidRequest }, privacyValues: privacy)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !SurfacePrivacyState.hides(tile.widget, values: privacy()) else {
            return .init(providerID: "seoAudit", message: "Hidden while presenting.")
        }
        let summaries = try await service.list()

        let selected = summaries.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
        let rows: [SurfaceDataRow] = selected.prefix(tile.itemLimit).map {
            .init(
                $0.id.uuidString, sourceID: $0.id.uuidString,
                title: String($0.name.prefix(256)), detail: String($0.baseURL.prefix(1_024)),
                value: $0.latestRun?.averageScore.map { "\($0)%" } ?? "Not run",
                icon: "globe")
        }
        let runs = selected.compactMap(\.latestRun)
        let metrics: [SurfaceMetric] = [
            .init("projects", "Projects", String(selected.count)),
            .init("pages", "Audited pages", String(runs.reduce(0) { $0 + $1.pageCount })),
            .init("issues", "Issues", String(runs.reduce(0) { $0 + $1.issueCount })),
        ]
        let sources: [SurfaceSourceChoice] = summaries.prefix(100).map {
            .init($0.id.uuidString, String($0.name.prefix(256)))
        }
        return .init(
            providerID: "seoAudit", metrics: metrics, rows: rows, sources: sources,
            message: selected.isEmpty ? "No site audit projects in this selection." : nil,
            updatedAt: summaries.map(\.updatedAt).max())
    }
}
