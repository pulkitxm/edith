import EdithExtensionSupport
@testable import NotchShelfExtension
import Testing

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

@Suite struct NotchHostAlertTests {
    @Test func permissionHintMatchesTheOriginalAlert() {
        let alert = NotchAlert.hostAlert(from: ["kind": "permissionHint"])
        #expect(alert?.id == "permissions.hint")
        #expect(alert?.settingsTab == "permissions")
        #expect(alert?.priority == .high)
        #expect(alert?.autoHide == 6)
    }

    @Test func updateReadyCarriesTheVersion() {
        let alert = NotchAlert.hostAlert(from: ["kind": "updateReady", "version": "0.0.400"])
        #expect(alert?.title == "Edith 0.0.400 is ready")
        #expect(alert?.subtitle == "Quit and reopen to finish")
        #expect(alert?.settingsTab == "updates")
    }

    @Test func malformedRequestsAreIgnored() {
        #expect(NotchAlert.hostAlert(from: ["kind": "updateReady"]) == nil)
        #expect(NotchAlert.hostAlert(from: ["kind": "updateReady", "version": ""]) == nil)
        #expect(NotchAlert.hostAlert(from: ["kind": "other"]) == nil)
        #expect(NotchAlert.hostAlert(from: [:]) == nil)
    }
}
