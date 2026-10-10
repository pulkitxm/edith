import Foundation
import Testing

@testable import EdithExtensionSupport

@Suite @MainActor struct ExtensionAmbientPolicyTests {
    @Test func originalCadenceKeepsOnlyDefinedLiveIntervalsOnBattery() {
        let ambient = ExtensionAmbientCadence(ambient: 900)
        let adaptive = ExtensionAmbientCadence(ambient: 900, live: 300)
        let live = ExtensionAmbientCadence(live: 5)
        #expect(ambient.interval(subscribers: 0, pauseAmbient: false) == 900)
        #expect(ambient.interval(subscribers: 1, pauseAmbient: true) == nil)
        #expect(adaptive.interval(subscribers: 0, pauseAmbient: true) == nil)
        #expect(adaptive.interval(subscribers: 1, pauseAmbient: true) == 300)
        #expect(adaptive.interval(subscribers: 128, pauseAmbient: false, constrained: true) == 300)
        #expect(adaptive.interval(subscribers: 0, pauseAmbient: false, constrained: true) == 2700)
        #expect(live.interval(subscribers: 0, pauseAmbient: false) == nil)
        #expect(live.interval(subscribers: 1, pauseAmbient: true) == 5)
        #expect(ExtensionAmbientCadence().interval(subscribers: 1, pauseAmbient: false) == nil)
    }

    @Test func invalidCadencesNeverAdmitPeriodicWork() {
        for value in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(
                ExtensionAmbientCadence(ambient: value).interval(
                    subscribers: 0, pauseAmbient: false) == nil)
            #expect(
                ExtensionAmbientCadence(live: value).interval(subscribers: 1, pauseAmbient: false)
                    == nil)
        }
        #expect(
            ExtensionAmbientCadence(ambient: .greatestFiniteMagnitude)
                .interval(subscribers: 0, pauseAmbient: false, constrained: true) == nil)
    }

    @Test func appliedPolicyAndInjectedPowerControlOnlyPeriodicAdmission() throws {
        let fixture = Fixture()
        let policy = fixture.policy()
        #expect(!policy.pauseAmbientOnBattery)
        #expect(policy.subscribers(for: "usage.refresh") == 0)
        #expect(policy.interval(for: "usage.refresh") == 900)
        try policy.apply(context: context(paused: true, refresh: 1, limits: 0))
        #expect(policy.interval(for: "usage.refresh") == nil)
        #expect(policy.interval(for: "usage.limits") == nil)
        try policy.apply(context: context(paused: true, refresh: 1, limits: 1))
        #expect(policy.interval(for: "usage.refresh") == nil)
        #expect(policy.interval(for: "usage.limits") == 300)
        fixture.onBattery = false
        #expect(policy.interval(for: "usage.refresh") == 900)
        fixture.constrained = true
        #expect(policy.interval(for: "usage.refresh") == 2700)
        fixture.onBattery = true
        try policy.apply(context: context(paused: false, refresh: 0, limits: 0))
        #expect(policy.interval(for: "usage.refresh") == 2700)
        #expect(policy.interval(for: "foreign") == nil)
        #expect(policy.subscribers(for: "foreign") == 0)
    }

    @Test func malformedContextCannotPartiallyChangeAppliedPolicyOrDemand() throws {
        let fixture = Fixture()
        let policy = fixture.policy()
        try policy.apply(context: context(paused: true, refresh: 0, limits: 1))
        let invalid: [NSDictionary] = [
            [:], ["ambientPolicy": "true"],
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": 1,
                    "subscribers": ["usage.refresh": 0, "usage.limits": 0],
                ]
            ],
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": false, "subscribers": ["usage.refresh": 0],
                ]
            ],
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": false,
                    "subscribers": ["foreign": 0, "usage.limits": 0],
                ]
            ],
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": false,
                    "subscribers": ["usage.refresh": 0, "usage.limits": 0], "foreign": true,
                ]
            ],
        ]
        for value in invalid {
            #expect(throws: ExtensionAmbientPolicyError.invalidContext) {
                try policy.apply(context: value)
            }
            #expect(policy.pauseAmbientOnBattery)
            #expect(policy.subscribers(for: "usage.limits") == 1)
        }
        for value: Any in [true, -1, 129, 1.5, 1.0, "1", NSNumber(value: UInt64.max)] {
            let input: NSDictionary = [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": false,
                    "subscribers": ["usage.refresh": value, "usage.limits": 0],
                ]
            ]
            #expect(throws: ExtensionAmbientPolicyError.invalidContext) {
                try policy.apply(context: input)
            }
            #expect(policy.pauseAmbientOnBattery)
            #expect(policy.subscribers(for: "usage.limits") == 1)
        }
        try policy.apply(context: context(paused: false, refresh: 128, limits: 0))
        #expect(policy.subscribers(for: "usage.refresh") == 128)
    }

    @Test func notificationObservationIsOwnedAndDoesNotCollectOrDuplicateTimers() throws {
        let fixture = Fixture()
        let center = NotificationCenter()
        let policy = fixture.policy(center: center)
        var changes = 0
        try policy.start { changes += 1 }
        try policy.start { changes += 100 }
        #expect(changes == 0)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(changes == 1)
        try policy.apply(context: context(paused: true, refresh: 0, limits: 0))
        #expect(changes == 2)
        try policy.apply(context: context(paused: true, refresh: 0, limits: 0))
        #expect(changes == 2)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(changes == 3)
        policy.stop()
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try policy.apply(context: context(paused: false, refresh: 0, limits: 0))
        #expect(changes == 3)
        try policy.start { changes += 1 }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(changes == 4)
        policy.stop()
    }

    @Test func instancesHaveIndependentPolicyAndRetirementRemovesObservers() throws {
        let fixture = Fixture()
        let center = NotificationCenter()
        var first: ExtensionAmbientPolicy? = fixture.policy(center: center)
        let second = fixture.policy(center: center)
        var changes = 0
        try first?.start { changes += 1 }
        try first?.apply(context: context(paused: true, refresh: 0, limits: 0))
        #expect(first?.interval(for: "usage.refresh") == nil)
        #expect(second.interval(for: "usage.refresh") == 900)
        #expect(!second.pauseAmbientOnBattery)
        weak var retired = first
        first = nil
        #expect(retired == nil)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(changes == 1)
    }

    @Test func injectedBatteryRegistrationWakesExistingSchedulingAndRetiresExactlyOnce() throws {
        let fixture = Fixture()
        var callback: (@MainActor () -> Void)?
        var registrations = 0
        var cancellations = 0
        var changes = 0
        let policy = ExtensionAmbientPolicy(
            jobs: ["companion.health": .init(ambient: 60, live: 20)],
            onBattery: { fixture.onBattery }, constrained: { false },
            notificationCenter: NotificationCenter(),
            observeBatteryChanges: { change in
                registrations += 1
                callback = change
                return { cancellations += 1 }
            })
        try policy.start { changes += 1 }
        try policy.start { changes += 100 }
        #expect(registrations == 1)
        callback?()
        #expect(changes == 1)
        policy.stop()
        policy.stop()
        #expect(cancellations == 1)
        callback?()
        #expect(changes == 1)
        try policy.start { changes += 1 }
        #expect(registrations == 2)
        callback?()
        #expect(changes == 2)
        policy.stop()
        #expect(cancellations == 2)
    }

    @Test func failedBatteryRegistrationDoesNotRetainObservationOrClaimSuccess() throws {
        var registrations = 0
        var changes = 0
        let center = NotificationCenter()
        let policy = ExtensionAmbientPolicy(
            jobs: ["machines.health": .init(ambient: 300)], onBattery: { true },
            constrained: { false },
            notificationCenter: center,
            observeBatteryChanges: { _ in
                registrations += 1
                throw ExtensionAmbientPolicyError.observationUnavailable
            })
        #expect(throws: ExtensionAmbientPolicyError.observationUnavailable) {
            try policy.start { changes += 1 }
        }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(changes == 0)
        #expect(throws: ExtensionAmbientPolicyError.observationUnavailable) {
            try policy.start { changes += 1 }
        }
        #expect(registrations == 2)
        policy.stop()
    }

    @Test func retiredPolicyReleasesItsInjectedBatteryRegistration() async throws {
        var cancellations = 0
        var policy: ExtensionAmbientPolicy? = ExtensionAmbientPolicy(
            jobs: ["machines.health": .init(ambient: 300)], onBattery: { false },
            constrained: { false },
            notificationCenter: NotificationCenter(),
            observeBatteryChanges: { _ in { cancellations += 1 } })
        try policy?.start {}
        weak var retired = policy
        policy = nil
        #expect(retired == nil)
        for _ in 0..<100 where cancellations == 0 { await Task.yield() }
        #expect(cancellations == 1)
    }

    private func context(paused: Bool, refresh: Int, limits: Int) -> NSDictionary {
        [
            "ambientPolicy": [
                "pauseAmbientOnBattery": paused,
                "subscribers": ["usage.refresh": refresh, "usage.limits": limits],
            ]
        ]
    }

    @MainActor private final class Fixture {
        var onBattery = true
        var constrained = false
        func policy(center: NotificationCenter = NotificationCenter()) -> ExtensionAmbientPolicy {
            ExtensionAmbientPolicy(
                jobs: [
                    "usage.refresh": .init(ambient: 900),
                    "usage.limits": .init(ambient: 900, live: 300),
                ],
                onBattery: { self.onBattery }, constrained: { self.constrained },
                notificationCenter: center,
                observeBatteryChanges: { _ in {} })
        }
    }
}
