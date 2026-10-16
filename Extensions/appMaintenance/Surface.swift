import EdithExtensionSupport
import Foundation

@MainActor
enum AppMaintenanceSurface {
    static func snapshot(_ model: AppMaintenanceModel, tile: SurfaceTile) -> SurfaceSnapshot {
        let selected = model.updates.filter { tile.sourceIDs?.contains($0.source.rawValue) ?? true }
        let metrics: [SurfaceMetric] =
            model.loading.hasContent
            ? [
                .init("updates", "Available updates", selected.count.description),
                .init("installed", "Installed apps", model.applications.count.description),
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
                    detail: String(($0.currentVersion + " → " + $0.availableVersion).prefix(4096)),
                    value: $0.source.title,
                    icon: "shippingbox")
            }, actions: actions,
            sources: AppUpdateSource.allCases.map { .init($0.rawValue, $0.title) },
            message: model.errorMessage
                ?? (model.checkingUpdates
                    ? "Checking for updates…"
                    : model.loading.hasContent
                        ? (selected.isEmpty ? "No cached updates in this selection." : nil)
                        : "Check for updates to read your installed apps."),
            updatedAt: model.lastUpdateRefresh)
    }
}
