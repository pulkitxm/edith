import EdithExtensionSupport
import Foundation
import Testing

@testable import MicMuteExtension

struct MicMuteExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let muted = MicMuteSurface.snapshot(muted: true)
        #expect(muted.metrics.first?.value == "Muted")
        #expect(muted.rows.isEmpty)
        #expect(muted.actions.first?.id == "toggle")
        #expect(muted.actions.first?.title == "Toggle mute")
        #expect(MicMuteSurface.snapshot(muted: false).metrics.first?.value == "On")
        _ = try SurfaceSnapshot.decode(muted.encoded(), providerID: "micMute")
    }
}
