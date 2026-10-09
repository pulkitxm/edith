import EdithExtensionSupport
import Foundation
import Testing
@testable import KeystrokeHighlightExtension

struct KeystrokeHighlightExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let active = KeystrokeHighlightSurface.snapshot(active: true)
        #expect(active.rows.first?.value == "Showing keystrokes")
        #expect(active.actions.first?.id == "disable")
        #expect(KeystrokeHighlightSurface.snapshot(active: false).actions.first?.id == "enable")
        _ = try SurfaceSnapshot.decode(active.encoded(), providerID: "keystrokeHighlight")
    }
}
