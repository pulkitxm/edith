import Testing
@testable import EdithHelper

@MainActor @Suite struct MusicPlayerIdleTests {
    @Test func idlePlayerReportsNoActivity() {
        let player = MusicPlayer()
        defer { player.shutdown() }
        #expect(!player.isPlaying)
        #expect(player.progressNow() == 0)
        #expect(player.elapsed == 0)
        #expect(player.trackDuration == 0)
    }
}
