import Foundation
import Testing

@testable import EdithHelper

@Suite struct NotchAlertQueueTests {
    private func alert(_ id: String) -> NotchAlert {
        NotchAlert(id: id, icon: "bolt.fill", title: id)
    }

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test func queueAppendsInOrder() {
        var pending: [PendingNotchAlert] = []
        pending = NotchAlertLogic.queue(pending, adding: alert("a"), at: epoch)
        pending = NotchAlertLogic.queue(pending, adding: alert("b"), at: epoch)
        #expect(pending.map(\.alert.id) == ["a", "b"])
    }

    @Test func queueReplacesSameIDAndMovesItLast() {
        var pending: [PendingNotchAlert] = []
        pending = NotchAlertLogic.queue(pending, adding: alert("a"), at: epoch)
        pending = NotchAlertLogic.queue(pending, adding: alert("b"), at: epoch)
        pending = NotchAlertLogic.queue(
            pending, adding: alert("a"), at: epoch.addingTimeInterval(5))
        #expect(pending.map(\.alert.id) == ["b", "a"])
        #expect(pending.count == 2)
    }

    @Test func queueDropsOldestBeyondLimit() {
        var pending: [PendingNotchAlert] = []
        for id in ["a", "b", "c", "d"] {
            pending = NotchAlertLogic.queue(pending, adding: alert(id), at: epoch)
        }
        #expect(pending.count == NotchAlertLogic.pendingLimit)
        #expect(pending.map(\.alert.id) == ["b", "c", "d"])
    }

    @Test func dequeueReturnsFirstAndRest() {
        var pending: [PendingNotchAlert] = []
        pending = NotchAlertLogic.queue(pending, adding: alert("a"), at: epoch)
        pending = NotchAlertLogic.queue(pending, adding: alert("b"), at: epoch)
        let (next, rest) = NotchAlertLogic.dequeue(pending, now: epoch.addingTimeInterval(1))
        #expect(next?.id == "a")
        #expect(rest.map(\.alert.id) == ["b"])
    }

    @Test func dequeueDropsStaleEntries() {
        var pending: [PendingNotchAlert] = []
        pending = NotchAlertLogic.queue(pending, adding: alert("stale"), at: epoch)
        pending = NotchAlertLogic.queue(
            pending, adding: alert("fresh"),
            at: epoch.addingTimeInterval(NotchAlertLogic.pendingTTL + 10))
        let (next, rest) = NotchAlertLogic.dequeue(
            pending, now: epoch.addingTimeInterval(NotchAlertLogic.pendingTTL + 11))
        #expect(next?.id == "fresh")
        #expect(rest.isEmpty)
    }

    @Test func dequeueOfEmptyOrAllStaleIsNil() {
        #expect(NotchAlertLogic.dequeue([], now: epoch).next == nil)
        let pending = NotchAlertLogic.queue([], adding: alert("a"), at: epoch)
        let (next, rest) = NotchAlertLogic.dequeue(
            pending, now: epoch.addingTimeInterval(NotchAlertLogic.pendingTTL + 1))
        #expect(next == nil)
        #expect(rest.isEmpty)
    }
}

@Suite struct PowerAlertLogicTests {
    @Test func plugInWhileChargingSaysCharging() {
        let alerts = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: true, charging: true, capacity: 55),
            lastOnAC: false, lastCapacity: 55)
        #expect(alerts.map(\.id) == ["power.charging"])
        #expect(alerts[0].title == "Charging")
        #expect(alerts[0].subtitle == "55%")
    }

    @Test func plugInWithFullBatterySaysPluggedIn() {
        let alerts = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: true, charging: false, capacity: 100),
            lastOnAC: false, lastCapacity: 100)
        #expect(alerts[0].title == "Plugged in")
    }

    @Test func unplugSaysOnBattery() {
        let alerts = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: false, charging: false, capacity: 80),
            lastOnAC: true, lastCapacity: 80)
        #expect(alerts[0].title == "On battery")
    }

    @Test func noStateChangeMeansNoAlert() {
        let alerts = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: true, charging: true, capacity: 60),
            lastOnAC: true, lastCapacity: 61)
        #expect(alerts.isEmpty)
    }

    @Test func batteryLowFiresOnlyWhenCrossingTwenty() {
        let crossing = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: false, charging: false, capacity: 20),
            lastOnAC: false, lastCapacity: 21)
        #expect(crossing.map(\.id) == ["battery.low"])
        #expect(crossing[0].priority == .high)

        let alreadyLow = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: false, charging: false, capacity: 19),
            lastOnAC: false, lastCapacity: 20)
        #expect(alreadyLow.isEmpty)
    }

    @Test func unplugAndLowBatteryTogetherYieldBoth() {
        let alerts = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(onAC: false, charging: false, capacity: 18),
            lastOnAC: true, lastCapacity: 22)
        #expect(alerts.map(\.id) == ["power.charging", "battery.low"])
    }

    @Test func unknownPowerStateIsSilent() {
        let alerts = NotchAlertLogic.powerAlerts(
            now: PowerSnapshot(), lastOnAC: nil, lastCapacity: nil)
        #expect(alerts.isEmpty)
    }
}
