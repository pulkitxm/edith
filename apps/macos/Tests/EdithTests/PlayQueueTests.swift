import Testing

@testable import EdithHelper

@Suite struct PlayQueueTests {
    @Test func advancesToNextTrack() {
        #expect(PlayQueue.index(after: 0, delta: 1, count: 3) == 1)
    }

    @Test func wrapsForwardPastTheEnd() {
        #expect(PlayQueue.index(after: 2, delta: 1, count: 3) == 0)
    }

    @Test func wrapsBackwardBeforeTheStart() {
        #expect(PlayQueue.index(after: 0, delta: -1, count: 3) == 2)
    }

    @Test func startsAtFirstTrackWhenNothingPlaying() {
        #expect(PlayQueue.index(after: nil, delta: 1, count: 3) == 0)
    }

    @Test func startsAtFirstTrackSteppingBackFromNothing() {
        #expect(PlayQueue.index(after: nil, delta: -1, count: 3) == 0)
    }

    @Test func hasNoIndexForAnEmptyQueue() {
        #expect(PlayQueue.index(after: nil, delta: 1, count: 0) == nil)
    }
}
