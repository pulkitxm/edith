import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class SEOAuditSurface {
    private let service: SEOAuditService
    private let open: @MainActor (UUID?) async -> Void
    private let privacy: @MainActor () -> [String: String]

    init(
        service: SEOAuditService,
        open: @escaping @MainActor (UUID?) async -> Void = { id in
            if let id { await SEOAuditModel.shared.selectProject(id: id) }
            ExtensionPresentation.showWindow()
        },
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) { self.service = service; self.open = open; self.privacy = privacy }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "seoAudit", command: command, payload: payload,
            snapshot: { [weak self] tile in
                guard let self else { throw ExtensionPeerError.unavailable }
                return try await self.snapshot(tile)
            },
            perform: { [weak self] action in
                guard let self else { throw ExtensionPeerError.unavailable }
                if action == "open" { await self.open(nil); return }
                let pieces = action.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, let id = UUID(uuidString: String(pieces[1])) else {
                    throw ExtensionPeerError.invalidRequest
                }
                _ = try await self.service.project(id)
                switch pieces[0] {
                case "open": await self.open(id)
                case "audit": _ = try await self.service.start(id, lighthouse: nil)
                case "cancel": _ = try await self.service.stop(id)
                default: throw ExtensionPeerError.invalidRequest
                }
            }, privacyValues: privacy)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !SurfacePrivacyState.hides(tile.widget, values: privacy()) else {
            return .init(providerID: "seoAudit", message: "Hidden while presenting.")
        }
        let summaries = try await service.list()
        let selected = summaries.filter {
            tile.sourceIDs?.contains($0.id.uuidString.lowercased()) ?? true
        }
        var rows: [SurfaceDataRow] = []
        for project in selected.prefix(tile.itemLimit) {
            try Task.checkCancellation()
            let id = project.id.uuidString.lowercased()
            let activity = service.activity(for: project.id)
            var actions: [SurfaceAction] = [
                .init("open:" + id, "Open project", "arrow.up.right.square")
            ]
            if activity != nil {
                actions.append(.init("cancel:" + id, "Cancel audit", "stop.circle"))
            } else if let draft = try? await service.draft(project.id),
                !draft.selectedPageURLs.isEmpty
            {
                actions.append(.init("audit:" + id, "Audit selected pages", "arrow.clockwise"))
            }
            let status =
                activity?.state.rawValue ?? project.latestRun?.state.rawValue ?? "Not audited"
            rows.append(
                .init(
                    "project:" + id, sourceID: id, title: String(project.name.prefix(256)),
                    detail: String(project.baseURL.prefix(1_024)), value: status,
                    icon: "checkmark.shield",
                    progress: activity?.progress, actions: actions))
        }
        let runs = selected.compactMap(\.latestRun)
        let metrics: [SurfaceMetric] = [
            .init("projects", "Projects", String(selected.count)),
            .init("pages", "Pages", String(runs.reduce(0) { $0 + $1.pageCount })),
            .init("issues", "Issues", String(runs.reduce(0) { $0 + $1.issueCount })),
        ]
        let sources: [SurfaceSourceChoice] = summaries.prefix(100).map {
            .init($0.id.uuidString.lowercased(), String($0.name.prefix(256)))
        }
        let message: String? =
            selected.isEmpty
            ? (tile.sourceIDs == nil
                ? "Add a project to begin a site audit." : "No selected projects.") : nil
        return .init(
            providerID: "seoAudit", metrics: metrics, rows: rows,
            actions: [.init("open", "Open Site Audit", "arrow.up.right.square")],
            sources: sources, message: message, updatedAt: selected.map(\.updatedAt).max())
    }
}
