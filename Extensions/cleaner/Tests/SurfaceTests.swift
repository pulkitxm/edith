import EdithExtensionSupport
import Foundation
import Testing
@testable import CleanerExtension

@Suite @MainActor
struct CleanerSurfaceTests {
    @Test func ScanResultsBecomeLiveMetricsWithoutOfferingDestructiveActions() async throws {
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
        #expect(CleanerSurface.snapshot(model).actions.first?.id == "scan")
        model.scan()
        #expect(CleanerSurface.snapshot(model).actions.first?.id == "cancel")
        await model.finishWork()
        let snapshot = CleanerSurface.snapshot(model)
        #expect(snapshot.rows.first?.title == "Synthetic cache")
        #expect(snapshot.metrics.map(\.id) == ["space", "categories"])
        #expect(snapshot.actions.map(\.id) == ["scan"])
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "cleaner")
        await model.shutdown()
    }
}
