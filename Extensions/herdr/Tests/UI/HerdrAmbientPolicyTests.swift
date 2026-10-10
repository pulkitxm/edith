import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

private actor HerdrAmbientFlight {
    private(set) var started = 0
    private(set) var completed = 0
    private(set) var cancelled = false
    private var waiting: CheckedContinuation<Void, Never>?

    func run() async {
        started += 1
        await withCheckedContinuation { waiting = $0 }
        cancelled = Task.isCancelled
        completed += 1
    }

    func finish() { waiting?.resume(); waiting = nil }
}

@MainActor @Suite(.serialized) struct HerdrAmbientPolicyTests {
    @Test func originalDefaultCadenceBatteryLiveDemandAndConstrainedPowerApply() async throws {
        var battery = true
        var constrained = false
        var powerChanged: (@MainActor () -> Void)?
        var stopped = 0
        let policy = ExtensionAmbientPolicy(
            jobs: ["sessions.discover": .init(ambient: 30, live: 2)],
            onBattery: { battery }, constrained: { constrained },
            notificationCenter: NotificationCenter(),
            observeBatteryChanges: { change in
                powerChanged = change
                return {
                    stopped += 1; powerChanged = nil
                }
            })
        let defaults = HerdrUIDefaults()
        let worker = makeWorker(defaults: defaults, policy: policy, automaticActions: true)
        #expect(worker.discoveryInterval == nil)
        try worker.applyAmbientPolicy(context: context(pause: false))
        #expect(worker.discoveryInterval == 30)
        try worker.applyAmbientPolicy(context: context(pause: true))
        #expect(worker.discoveryInterval == nil)
        try worker.applyAmbientPolicy(context: context(pause: true, subscribers: 1))
        #expect(worker.discoveryInterval == 2)
        constrained = true
        powerChanged?()
        #expect(worker.discoveryInterval == 2)
        try worker.applyAmbientPolicy(context: context(pause: true))
        battery = false
        powerChanged?()
        #expect(worker.discoveryInterval == 90)
        await worker.shutdown()
        #expect(stopped == 1 && powerChanged == nil && worker.discoveryInterval == nil)
    }

    @Test func originalNotificationsTrackingAndSubscriptionsAreActualDemand() async throws {
        let defaults = HerdrUIDefaults()
        HerdrAttentionSettings(blocked: false, finished: false, errors: false).save(in: defaults)
        var version: String? = "fixture-v1"
        var tracking = false
        var reads = 0
        let worker = makeWorker(
            defaults: defaults,
            tracking: {
                reads += 1; return tracking
            }, version: { version })
        try worker.applyAmbientPolicy(context: context(pause: false))
        #expect(worker.discoveryInterval == nil)
        await worker.refreshDiscoveryDemand()
        #expect(worker.discoveryInterval == nil && reads == 1)
        tracking = true
        await worker.refreshDiscoveryDemand()
        #expect(worker.discoveryInterval == 30)
        version = nil
        #expect(worker.discoveryInterval == nil)
        await worker.refreshDiscoveryDemand()
        #expect(reads == 2 && worker.discoveryInterval == nil)
        try worker.applyAmbientPolicy(context: context(pause: false, subscribers: 1))
        #expect(worker.discoveryInterval == 2)
        try worker.applyAmbientPolicy(context: context(pause: false))
        #expect(worker.discoveryInterval == nil)
        defaults.set(true, forKey: HerdrAttentionSettings.Keys.notifyWhenBlocked)
        #expect(worker.discoveryInterval == 30)
        await worker.shutdown()
    }

    @Test func malformedPolicyAndPublicCommandsCannotForgeLiveDemand() async throws {
        let worker = makeWorker(defaults: HerdrUIDefaults())
        try worker.applyAmbientPolicy(context: context(pause: true))
        for invalid: NSDictionary in [
            [:],
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": true, "subscribers": ["sessions.discover": true],
                ]
            ],
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": true, "subscribers": ["sessions.discover": 129],
                ]
            ],
            ["ambientPolicy": ["pauseAmbientOnBattery": true, "subscribers": ["other": 1]]],
        ] {
            #expect(throws: ExtensionAmbientPolicyError.self) {
                try worker.applyAmbientPolicy(context: invalid)
            }
            #expect(worker.discoveryInterval == nil)
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.ambientPolicy", payload: Data("{}".utf8))
        }
        let settings = try await worker.execute("herdr.settings.read", payload: Data("{}".utf8))
        let object = try JSONSerialization.jsonObject(with: settings) as? [String: Any]
        #expect(object?["blocked"] as? Bool == true)
        #expect(worker.discoveryInterval == nil)
        await worker.shutdown()
    }

    @Test func policyChangesPreserveTheRealPollingFlightAndCancelOnlyFutureAdmissions() async throws
    {
        let worker = makeWorker(defaults: HerdrUIDefaults())
        try worker.applyAmbientPolicy(context: context(pause: false, subscribers: 1))
        let admission = try #require(HerdrLive.admission)
        let flight = HerdrAmbientFlight()
        let polling = Task {
            await HerdrLive.poll(admission: admission, key: "fixture.snapshot") {
                await flight.run()
            }
        }
        #expect(await waitUntil { await flight.started == 1 })
        try worker.applyAmbientPolicy(context: context(pause: true))
        #expect(await flight.completed == 0)
        #expect(await !flight.cancelled)
        await flight.finish()
        #expect(await waitUntil { await flight.completed == 1 && admission.pendingCount == 1 })
        #expect(await flight.started == 1)
        #expect(await !flight.cancelled)
        let settings = try await worker.execute("herdr.settings.read", payload: Data("{}".utf8))
        #expect(!settings.isEmpty)
        try worker.applyAmbientPolicy(context: context(pause: true, subscribers: 1))
        #expect(await waitUntil { await flight.started == 2 })
        await flight.finish()
        polling.cancel()
        await polling.value
        await worker.shutdown()
        #expect(admission.pendingCount == 0 && admission.timerCount == 0 && admission.stopped)
    }

    @Test func trackingSettingsDecodeOnlyStrictFieldsAndRejectRetiredOwners() async {
        var version: String? = "fixture-v1"
        var calls: [(String, Data)] = []
        let activeVersion = { @MainActor in version }
        let valid = Data(
            #"{"isEnabled":true,"agentTrackingEnabled":true,"serverToken":"synthetic-secret","profileNote":"synthetic-profile"}"#
                .utf8)
        #expect(
            await HerdrTrackingDemand.read(activeVersion: activeVersion) { operation, payload in
                calls.append((operation, payload)); return valid
            })
        #expect(calls.count == 1 && calls[0].0 == "attention.settings.get")
        #expect(calls[0].1 == Data("{}".utf8))
        for data in [
            Data(#"{"isEnabled":1,"agentTrackingEnabled":true}"#.utf8),
            Data(#"{"isEnabled":true}"#.utf8),
            Data(#"{"isEnabled":false,"agentTrackingEnabled":true}"#.utf8),
            Data(#"{"isEnabled":true,"agentTrackingEnabled":false}"#.utf8),
            Data(repeating: 0, count: 1_048_577),
        ] {
            #expect(
                await HerdrTrackingDemand.read(activeVersion: activeVersion) { _, _ in data }
                    == false)
        }
        #expect(
            await HerdrTrackingDemand.read(activeVersion: activeVersion) { _, _ in
                version = "fixture-v2"; return valid
            } == false)
        version = nil
        #expect(
            await HerdrTrackingDemand.read(activeVersion: activeVersion) { _, _ in
                calls.append(("unexpected", Data())); return valid
            } == false)
        #expect(calls.count == 1)
    }

    private func context(pause: Bool, subscribers: Int = 0) -> NSDictionary {
        [
            "ambientPolicy": [
                "pauseAmbientOnBattery": pause, "subscribers": ["sessions.discover": subscribers],
            ]
        ]
    }

    private func makeWorker(
        defaults: HerdrUIDefaults, policy: ExtensionAmbientPolicy? = nil,
        tracking: @escaping @MainActor () async throws -> Bool = { false },
        version: @escaping @MainActor () -> String? = { "fixture-v1" },
        automaticActions: Bool = false
    ) -> HerdrWorker {
        let policy =
            policy
            ?? ExtensionAmbientPolicy(
                jobs: ["sessions.discover": .init(ambient: 30, live: 2)],
                onBattery: { true }, constrained: { false },
                notificationCenter: NotificationCenter(),
                observeBatteryChanges: { _ in {} })
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        return HerdrWorker(
            store: store, defaults: defaults, ambientPolicy: policy, trackingDemand: tracking,
            trackingOwnerVersion: version, automaticActions: automaticActions)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        return await condition()
    }
}
