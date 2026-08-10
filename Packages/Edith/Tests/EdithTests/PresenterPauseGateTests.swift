import Testing
@testable import EdithHelper

@Suite struct PresenterPauseGateTests {
    @Test func staysPausedWhileTheShareContinues() {
        #expect(PresenterPauseGate.stillPaused(hit: true))
    }

    @Test func clearsAsSoonAsTheShareEnds() {
        #expect(!PresenterPauseGate.stillPaused(hit: false))
    }

    @Test func doesNotRequireTheSourceAppToQuit() {
        let stillSharingWithAppOpen = true
        #expect(PresenterPauseGate.stillPaused(hit: stillSharingWithAppOpen))
        let stoppedSharingWithAppStillOpen = false
        #expect(!PresenterPauseGate.stillPaused(hit: stoppedSharingWithAppStillOpen))
    }
}
