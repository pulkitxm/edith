import Foundation
import Testing
@testable import EdithHelper

private final class NotificationReplacementProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
}

@Suite struct UpdateNotifierTests {
    @Test func versionIsReadFromTheIPCPayload() {
        #expect(UpdateNotifier.version(from: ["version": "0.0.25"]) == "0.0.25")
    }

    @Test func missingOrEmptyVersionIsRejected() {
        #expect(UpdateNotifier.version(from: [:]) == nil)
        #expect(UpdateNotifier.version(from: ["version": ""]) == nil)
        #expect(UpdateNotifier.version(from: ["version": 25]) == nil)
    }

    @Test func titleNamesTheVersion() {
        #expect(UpdateNotifier.title(for: "0.0.25") == "Edith 0.0.25 is ready")
    }

    @Test func bodyAsksForARelaunch() {
        #expect(UpdateNotifier.body.lowercased().contains("reopen"))
    }

    @Test func notchAlertCarriesTheVersionAndRoutesToUpdates() {
        let alert = UpdateNotifier.alert(for: "0.0.25")
        #expect(alert.title == "Edith 0.0.25 is ready")
        #expect(alert.settingsTab == "updates")
        #expect(alert.priority == .high)
        #expect(alert.autoHide > 3)
    }

    @Test func repeatedAlertsForTheSameVersionShareAnIdentity() {
        #expect(UpdateNotifier.alert(for: "0.0.25").id == UpdateNotifier.alert(for: "0.0.26").id)
    }

    @Test func alertPreemptsALowerPriorityOne() {
        let existing = NotchAlert(id: "power.ac", icon: "bolt", title: "Charging", priority: .low)
        #expect(
            NotchAlertLogic.shouldPreempt(
                current: existing, incoming: UpdateNotifier.alert(for: "0.0.25")))
    }

    @Test func stalledNotificationCenterDoesNotBlockUpdateCaller() {
        let probe = NotificationReplacementProbe()
        let queue = NotificationReplacementQueue(
            label: "test.update-notifications.\(UUID().uuidString)"
        ) { _ in
            probe.entered.signal()
            probe.release.wait()
        }

        DispatchQueue.global().async {
            UpdateNotifier.notify(version: "0.0.25", queue: queue)
            probe.returned.signal()
        }

        #expect(probe.entered.wait(timeout: .now() + 1) == .success)
        #expect(probe.returned.wait(timeout: .now() + 0.2) == .success)
        probe.release.signal()
    }
}
