import EdithExtensionSupport
import Foundation

@MainActor
enum CleanerSurface {
    static func snapshot(_ model: CleanerModel) -> SurfaceSnapshot {
        let metrics: [SurfaceMetric] =
            model.scanned
            ? [
                .init("space", "Reclaimable", JunkScanner.format(model.reclaimableTotal)),
                .init("categories", "Categories", model.categories.count.description),
            ]
            : model.latestEstimate.map {
                [
                    .init("space", "Reclaimable", JunkScanner.format($0.reclaimableBytes)),
                    .init("categories", "Categories", $0.categoryCount.description),
                ]
            } ?? []
        let actions: [SurfaceAction] = [
            .init(
                model.scanning ? "cancel" : "scan", model.scanning ? "Cancel scan" : "Scan",
                model.scanning ? "xmark.circle" : "magnifyingglass")
        ]
        return .init(
            providerID: "cleaner", metrics: metrics,
            rows: model.categories.prefix(100).map {
                .init(
                    $0.id, title: String($0.name.prefix(1024)),
                    detail: $0.items.count.description + " items",
                    value: JunkScanner.format($0.sizeBytes), icon: "trash")
            }, actions: actions,
            message: model.scanning
                ? model.operationTitle
                : model.scanned || model.latestEstimate != nil
                    ? nil : "Scan your configured folders to see reclaimable space.",
            updatedAt: model.latestEstimate?.scannedAt)
    }
}
