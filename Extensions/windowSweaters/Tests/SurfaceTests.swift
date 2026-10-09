import EdithExtensionSupport
import Foundation
import Testing
@testable import WindowSweatersExtension

struct WindowSweatersExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let active = WindowSweatersSurface.snapshot(active: true, pattern: "cable")
        #expect(active.rows.first?.detail == "cable")
        #expect(active.actions.first?.id == "disable")
        #expect(
            WindowSweatersSurface.snapshot(active: false, pattern: "plain").actions.first?.id
                == "enable")
        _ = try SurfaceSnapshot.decode(active.encoded(), providerID: "windowSweaters")
    }
}
