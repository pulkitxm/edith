import Testing
@testable import Edith

@Suite struct TabReorderTests {
    private let order = ["usage", "music", "system", "calendar"]

    @Test func movesDown() {
        #expect(
            movedTabOrder(order, from: 0, by: 2) == ["music", "system", "usage", "calendar"])
    }

    @Test func movesUp() {
        #expect(
            movedTabOrder(order, from: 2, by: -2) == ["system", "usage", "music", "calendar"])
    }

    @Test func clampsBelowStart() {
        #expect(
            movedTabOrder(order, from: 1, by: -5) == ["music", "usage", "system", "calendar"])
    }

    @Test func clampsPastEnd() {
        #expect(
            movedTabOrder(order, from: 1, by: 9) == ["usage", "system", "calendar", "music"])
    }

    @Test func zeroDeltaKeepsOrder() {
        #expect(movedTabOrder(order, from: 1, by: 0) == order)
    }

    @Test func clampedMoveFromEndKeepsOrder() {
        #expect(movedTabOrder(order, from: 3, by: 4) == order)
    }

    @Test func invalidIndexKeepsOrder() {
        #expect(movedTabOrder(order, from: 9, by: 1) == order)
        #expect(movedTabOrder([], from: 0, by: 1).isEmpty)
    }
}
