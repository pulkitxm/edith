import Foundation
import Testing
@testable import EdithHelper

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
}
