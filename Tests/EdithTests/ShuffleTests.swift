import Testing
@testable import Edith

@Suite struct ShuffleTests {
    @Test func excludesCurrentWhenAlternativesExist() {
        #expect(Shuffle.pool([1, 2, 3], excluding: 2) == [1, 3])
    }

    @Test func fallsBackToWholeListForSingleTrack() {
        #expect(Shuffle.pool([1], excluding: 1) == [1])
    }

    @Test func keepsEverythingWhenNothingPlaying() {
        #expect(Shuffle.pool([1, 2], excluding: nil) == [1, 2])
    }
}
