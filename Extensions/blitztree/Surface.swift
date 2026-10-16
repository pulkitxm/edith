import EdithExtensionSupport
import Foundation

enum BlitzTreeSurface {
    private struct Estimate: Decodable {
        let scannedAt: Date
        let reclaimableBytes: Int64
        let categoryCount: Int
    }

    static let estimateKey = "cleaner.backgroundEstimate"

    static func snapshot(defaults: UserDefaults = SharedDefaults.store) -> SurfaceSnapshot {
        guard let data = defaults.data(forKey: estimateKey), data.count <= 1_024,
            let estimate = try? JSONDecoder().decode(Estimate.self, from: data),
            estimate.reclaimableBytes >= 0, (0...10_000).contains(estimate.categoryCount)
        else { return .init(providerID: "blitztree") }
        return .init(
            providerID: "blitztree",
            metrics: [
                .init(
                    "space", "Reclaimable",
                    ByteCountFormatter.string(
                        fromByteCount: estimate.reclaimableBytes, countStyle: .file)),
                .init("categories", "Categories", estimate.categoryCount.description),
            ], updatedAt: estimate.scannedAt)
    }
}
