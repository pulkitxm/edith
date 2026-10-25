import EdithExtensionSupport
import Foundation
import Testing

@testable import HingeExtension

struct HingeExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let active = HingeSurface.snapshot(active: true)
        #expect(active.metrics.first?.value == "On")
        #expect(active.rows.isEmpty)
        #expect(active.actions.first?.id == "disable")
        #expect(active.actions.first?.title == "Turn off")
        let inactive = HingeSurface.snapshot(active: false)
        #expect(inactive.metrics.first?.value == "Off")
        #expect(inactive.actions.first?.id == "enable")
        _ = try SurfaceSnapshot.decode(active.encoded(), providerID: "hinge")
    }
}
