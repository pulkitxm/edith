import Testing
@testable import EdithMenuBar

@Suite struct PresenterDebouncerTests {
    @Test func turnsOnAtFirstHit() {
        var d = PresenterDebouncer()
        #expect(!d.active)
        let result = d.record(hit: true)
        #expect(result)
        #expect(d.active)
    }

    @Test func staysOnThroughASingleMiss() {
        var d = PresenterDebouncer()
        _ = d.record(hit: true)
        let result = d.record(hit: false)
        #expect(result)
        #expect(d.active)
    }

    @Test func turnsOffAfterTwoConsecutiveMisses() {
        var d = PresenterDebouncer()
        _ = d.record(hit: true)
        _ = d.record(hit: false)
        let result = d.record(hit: false)
        #expect(!result)
        #expect(!d.active)
    }

    @Test func hitDuringMissStreakResetsMisses() {
        var d = PresenterDebouncer()
        _ = d.record(hit: true)
        _ = d.record(hit: false)
        let reHit = d.record(hit: true)
        #expect(reHit)
        let afterOneMiss = d.record(hit: false)
        #expect(afterOneMiss)
        #expect(d.active)
    }

    @Test func staysOffWithoutAHit() {
        var d = PresenterDebouncer()
        let first = d.record(hit: false)
        #expect(!first)
        let second = d.record(hit: false)
        #expect(!second)
        #expect(!d.active)
    }
}
