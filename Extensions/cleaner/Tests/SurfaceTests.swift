import EdithExtensionSupport
import Foundation
import Testing
@testable import CleanerExtension

@Suite @MainActor
struct CleanerSurfaceTests {
    @Test func ScanResultsBecomeEstimateMetricsWithoutRowsOrActions() async throws {
        let defaults = UserDefaults(suiteName: "test.cleaner.surface." + UUID().uuidString)!
        let model = CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] },
                scan: { _, _, _ in
                    CleanerScanResult(categories: [
                        .init(
                            id: "cache", name: "Synthetic cache", detail: "Cache files",
                            items: [
                                .init(
                                    id: "one", name: "sample.cache",
                                    path: URL(fileURLWithPath: "/synthetic/sample.cache"),
                                    sizeBytes: 1024, selected: true)
                            ])
                    ])
                }))
        #expect(CleanerSurface.snapshot(model).metrics.isEmpty)
        #expect(CleanerSurface.snapshot(model).actions.isEmpty)
        model.scan()
        await model.finishWork()
        let snapshot = CleanerSurface.snapshot(model)
        #expect(snapshot.rows.isEmpty && snapshot.actions.isEmpty)
        #expect(snapshot.metrics.map(\.id) == ["space", "categories"])
        #expect(snapshot.metrics.map(\.title) == ["Reclaimable", "Categories"])
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "cleaner")
        await model.shutdown()
    }
}
