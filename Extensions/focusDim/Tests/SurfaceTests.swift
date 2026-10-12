import EdithExtensionSupport
import Foundation
import Testing
@testable import FocusDimExtension

struct FocusDimExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let active = FocusDimSurface.snapshot(active: true, intensity: 0.42)
        #expect(active.rows.first?.detail == "Intensity 42%")
        #expect(active.actions.first?.id == "disable")
        #expect(
            FocusDimSurface.snapshot(active: false, intensity: 5).rows.first?.detail
                == "Intensity 100%")
        _ = try SurfaceSnapshot.decode(active.encoded(), providerID: "focusDim")
    }
}
