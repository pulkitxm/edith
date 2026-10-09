import EdithExtensionSupport
import Foundation
import Testing
@testable import KeepAwakeExtension

struct KeepAwakeExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let off = KeepAwakeSurface.snapshot(preventingSleep: false, requested: false)
        let failed = KeepAwakeSurface.snapshot(preventingSleep: false, requested: true)
        #expect(off.rows.first?.value == "Off")
        #expect(off.actions.first?.id == "enable")
        #expect(failed.actions.first?.id == "disable")
        #expect(failed.message != nil)
        _ = try SurfaceSnapshot.decode(failed.encoded(), providerID: "keepAwake")
    }
}
