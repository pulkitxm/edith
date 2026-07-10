import Testing

@testable import EdithMenuBar

@Suite struct NotchAlertLogicTests {
    private func alert(_ id: String, _ priority: NotchAlertPriority) -> NotchAlert {
        NotchAlert(id: id, icon: "x", title: id, priority: priority)
    }

    @Test func anyAlertPreemptsWhenNoneShowing() {
        #expect(NotchAlertLogic.shouldPreempt(current: nil, incoming: alert("a", .low)))
    }

    @Test func sameIdUpdatesInPlace() {
        #expect(
            NotchAlertLogic.shouldPreempt(current: alert("a", .high), incoming: alert("a", .low)))
    }

    @Test func higherPriorityPreempts() {
        #expect(
            NotchAlertLogic.shouldPreempt(current: alert("a", .low), incoming: alert("b", .high)))
    }

    @Test func equalPriorityPreempts() {
        #expect(
            NotchAlertLogic.shouldPreempt(
                current: alert("a", .medium), incoming: alert("b", .medium)))
    }

    @Test func lowerPriorityDoesNotPreempt() {
        #expect(
            !NotchAlertLogic.shouldPreempt(
                current: alert("a", .critical), incoming: alert("b", .low)))
    }
}
