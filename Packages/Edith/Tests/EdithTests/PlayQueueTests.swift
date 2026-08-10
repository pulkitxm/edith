import EdithKit
import Foundation
import Testing

@testable import EdithHelper

@Suite struct PlayQueueTests {
    private func tracks(_ names: [String]) -> [Track] {
        names.map { Track(url: URL(fileURLWithPath: "/music/\($0).mp3"), relativePath: $0) }
    }

    @Test func shuffleKeepsEveryTrack() {
        let list = tracks(["a", "b", "c", "d", "e"])
        let shuffled = PlayQueue.shuffled(list, startingWith: nil)
        #expect(shuffled.count == list.count)
        #expect(Set(shuffled.map(\.relativePath)) == Set(list.map(\.relativePath)))
    }

    @Test func shuffleStartsFromTheCurrentTrack() {
        let list = tracks(["a", "b", "c", "d", "e"])
        for _ in 0..<20 {
            let shuffled = PlayQueue.shuffled(list, startingWith: list[3])
            #expect(shuffled.first == list[3])
        }
    }

    @Test func shuffleHandlesACurrentTrackOutsideTheQueue() {
        let list = tracks(["a", "b"])
        let outsider = tracks(["z"])[0]
        let shuffled = PlayQueue.shuffled(list, startingWith: outsider)
        #expect(Set(shuffled.map(\.relativePath)) == Set(list.map(\.relativePath)))
    }

    @Test func shuffleOrderSurvivesARescan() {
        let list = tracks(["a", "b", "c", "d"])
        let first = PlayQueue.shuffleOrder(previous: nil, natural: list, current: list[0])
        let again = PlayQueue.shuffleOrder(previous: first, natural: list, current: list[0])
        #expect(again.map(\.relativePath) == first.map(\.relativePath))
    }

    @Test func shuffleOrderDropsGoneTracksAndAppendsNewOnes() {
        let list = tracks(["a", "b", "c"])
        let previous = PlayQueue.shuffleOrder(previous: nil, natural: list, current: nil)
        let changed = tracks(["a", "c", "d"])
        let order = PlayQueue.shuffleOrder(previous: previous, natural: changed, current: nil)
        #expect(Set(order.map(\.relativePath)) == Set(changed.map(\.relativePath)))
        let kept = previous.map(\.relativePath).filter { $0 != "b" }
        #expect(order.prefix(kept.count).map(\.relativePath) == kept)
        #expect(order.last?.relativePath == "d")
    }

    @Test func shuffleOfAnEmptyQueueIsEmpty() {
        #expect(PlayQueue.shuffled([], startingWith: nil).isEmpty)
    }

    @Test func previousRestartsAfterTheThreshold() {
        #expect(PlayQueue.previousRestarts(elapsed: 60))
        #expect(PlayQueue.previousRestarts(elapsed: PlayQueue.restartThreshold + 0.1))
    }

    @Test func previousStepsBackEarlyInTheTrack() {
        #expect(!PlayQueue.previousRestarts(elapsed: 0))
        #expect(!PlayQueue.previousRestarts(elapsed: PlayQueue.restartThreshold))
    }

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
