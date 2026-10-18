import Testing

@testable import MusicExtension
import EdithExtensionSupport
import EdithExtensionUI

extension MusicExtensionTests {
    @MainActor @Suite struct MusicPlayerIdleTests {
        @Test func idlePlayerReportsNoActivity() {
            let player = LocalMusicPlayer()
            defer { player.shutdown() }
            #expect(!player.isPlaying)
            #expect(player.progressNow() == 0)
            #expect(player.elapsed == 0)
            #expect(player.trackDuration == 0)
        }
    }

}
