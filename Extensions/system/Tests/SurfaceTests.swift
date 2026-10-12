import EdithExtensionSupport
import Testing
@testable import SystemExtension

struct SystemSurfaceTests {
    @Test func AppActionsUseCurrentProcessIDsAndQuickActionsDoNotExposeNames() throws {
        let apps = [
            RunningAppSnapshot(
                pid: 123, name: "Synthetic editor", bundleID: "test.editor", active: true)
        ]
        let snapshot = SystemSurface.snapshot(apps: apps, tile: .init(.ability("system")))
        #expect(snapshot.rows.first?.actions.first?.id == "activate:123")
        #expect(snapshot.rows.first?.value == "Frontmost")
        let quick = SystemSurface.snapshot(apps: apps, tile: .init(.actions))
        #expect(quick.rows.isEmpty)
        #expect(quick.metrics.first?.value == "1")
        #expect(!snapshot.actions.contains { $0.id.contains("quit") })
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "system")
    }
}
