import EdithExtensionSupport
import Foundation

@MainActor
enum CleanerSurface {
    static func snapshot(_ model: CleanerModel) -> SurfaceSnapshot {
        let metrics: [SurfaceMetric] =
            model.latestEstimate.map {
                [
                    .init("space", "Reclaimable", JunkScanner.format($0.reclaimableBytes)),
                    .init("categories", "Categories", $0.categoryCount.description),
                ]
            } ?? []
        return .init(
            providerID: "cleaner", metrics: metrics, updatedAt: model.latestEstimate?.scannedAt)
    }
}
