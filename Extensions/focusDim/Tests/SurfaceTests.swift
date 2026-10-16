import EdithExtensionSupport
import Foundation
import Testing

@testable import FocusDimExtension

struct FocusDimExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let active = FocusDimSurface.snapshot(active: true)
        #expect(active.metrics.first?.value == "On")
        #expect(active.rows.isEmpty)
        #expect(active.actions.first?.id == "disable")
        #expect(active.actions.first?.title == "Turn off")
        let inactive = FocusDimSurface.snapshot(active: false)
        #expect(inactive.metrics.first?.value == "Off")
        #expect(inactive.actions.first?.id == "enable")
        _ = try SurfaceSnapshot.decode(active.encoded(), providerID: "focusDim")
    }
}
