import EdithExtensionSupport
import Foundation

@MainActor
enum AppMaintenanceSurface {
    static func snapshot(_ model: AppMaintenanceModel, tile: SurfaceTile) -> SurfaceSnapshot {
        let selected = model.updates.filter { tile.sourceIDs?.contains($0.source.rawValue) ?? true }
        let metrics: [SurfaceMetric] =
            model.loading.hasContent
            ? [
                .init("installed", "Installed apps", model.applications.count.description),
                .init("updates", "Updates", selected.count.description),
            ] : []
        let actions: [SurfaceAction] =
            model.mutationInProgress
            ? []
            : [
                .init(
                    model.checkingUpdates ? "cancel" : "refresh",
                    model.checkingUpdates ? "Cancel check" : "Check updates",
                    model.checkingUpdates ? "xmark.circle" : "arrow.clockwise")
            ]
        return .init(
            providerID: "appMaintenance", metrics: metrics,
            rows: selected.prefix(100).map {
                .init(
                    $0.id, sourceID: $0.source.rawValue, title: String($0.name.prefix(1024)),
                    detail: $0.source.title,
                    value: String(($0.currentVersion + " to " + $0.availableVersion).prefix(256)),
                    icon: "app")
            }, actions: actions,
            sources: AppUpdateSource.allCases.map { .init($0.rawValue, $0.title) },
            message: model.errorMessage
                ?? (model.checkingUpdates
                    ? "Checking for updates…"
                    : model.loading.hasContent
                        ? nil : "Check for updates to read your installed apps."),
            updatedAt: model.lastUpdateRefresh)
    }
}
