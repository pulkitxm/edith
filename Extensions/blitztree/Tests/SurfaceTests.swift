import EdithExtensionSupport
import Foundation
import Testing
@testable import BlitzTreeExtension

@Suite @MainActor
struct BlitzTreeSurfaceTests {
    @Test func missingEstimateShowsNoMetrics() throws {
        let defaults = UserDefaults(suiteName: "blitztree.surface.empty")!
        defaults.removePersistentDomain(forName: "blitztree.surface.empty")
        let snapshot = BlitzTreeSurface.snapshot(defaults: defaults)
        #expect(snapshot.metrics.isEmpty)
        #expect(snapshot.actions.isEmpty)
        #expect(snapshot.updatedAt == nil)
    }

    @Test func cleanerEstimateIsProjectedAsReclaimableSpace() throws {
        let defaults = UserDefaults(suiteName: "blitztree.surface.estimate")!
        defaults.removePersistentDomain(forName: "blitztree.surface.estimate")
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        let data = try encoder.encode(
            [
                "scannedAt": scanned.timeIntervalSinceReferenceDate, "reclaimableBytes": 4096.0,
                "categoryCount": 3.0,
            ])
        defaults.set(data, forKey: BlitzTreeSurface.estimateKey)
        let snapshot = BlitzTreeSurface.snapshot(defaults: defaults)
        #expect(snapshot.metrics.map(\.id) == ["space", "categories"])
        #expect(snapshot.metrics.map(\.title) == ["Reclaimable", "Categories"])
        #expect(snapshot.updatedAt == scanned)
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "blitztree")
    }
}
