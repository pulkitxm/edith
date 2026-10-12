import EdithExtensionSupport
import Foundation
import Testing
@testable import MicMuteExtension

struct MicMuteExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let muted = MicMuteSurface.snapshot(muted: true, error: "Microphone unavailable")
        #expect(muted.rows.first?.value == "Muted")
        #expect(muted.actions.first?.id == "unmute")
        #expect(muted.message == "Microphone unavailable")
        #expect(MicMuteSurface.snapshot(muted: false, error: nil).actions.first?.id == "mute")
        _ = try SurfaceSnapshot.decode(muted.encoded(), providerID: "micMute")
    }
}
