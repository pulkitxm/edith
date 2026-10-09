import EdithExtensionSupport
import Foundation
import Testing
@testable import AppMaintenanceExtension

@Suite @MainActor
struct AppMaintenanceSurfaceTests {
    @Test func KindsFilterCurrentUpdatesAndKeepMutationsInTheirPreviewPage() throws {
        let model = AppMaintenanceModel(inventory: { _ in [] }, discover: { _, _, _, _ in [] })
        model.loading.retainContent()
        model.updates = [
            AppUpdateItem(
                id: "synthetic", name: "Synthetic app", bundleID: "test.app", applicationPath: nil,
                source: .appStore, currentVersion: "1", availableVersion: "2", releaseTitle: nil,
                releaseNotes: nil, releaseURL: nil, confidence: .high, checkedAt: Date(),
                action: .install, executablePath: "/synthetic/tool", arguments: [])
        ]
        var tile = SurfaceTile(.ability("appMaintenance"))
        let snapshot = AppMaintenanceSurface.snapshot(model, tile: tile)
        #expect(snapshot.rows.first?.sourceID == "appStore")
        #expect(snapshot.rows.first?.value == "1 to 2")
        #expect(snapshot.rows.flatMap(\.actions).isEmpty)
        tile.sourceIDs = ["sparkle"]
        #expect(AppMaintenanceSurface.snapshot(model, tile: tile).rows.isEmpty)
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "appMaintenance")
    }
}
