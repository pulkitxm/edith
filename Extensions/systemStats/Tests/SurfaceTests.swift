import EdithExtensionSupport
import Foundation
import Testing
@testable import SystemStatsExtension

struct SystemStatsExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let snapshot = SystemStatsSurface.snapshot(cpu: 37, memory: 62, freeDiskBytes: 1024)
        #expect(snapshot.metrics.map(\.id) == ["cpu", "memory", "disk"])
        #expect(snapshot.metrics.first?.fraction == 0.37)
        var tile = SurfaceTile(.ability("systemStats"))
        tile.hiddenFields = ["cpu", "disk"]
        #expect(SurfaceCommandService.project(snapshot, tile: tile).metrics.map(\.id) == ["memory"])
        #expect(
            SystemStatsSurface.snapshot(cpu: 0, memory: 0, freeDiskBytes: nil).metrics.count == 2)
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "systemStats")
    }
}
