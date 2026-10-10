import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite(.serialized) struct HostAmbientPolicyCoordinatorTests {
    @Test func closedContextIncludesEveryOwnedJobAndRejectsUntrustedDemand() throws {
        for (owner, jobs) in HostAmbientPolicy.jobs {
            let policy = HostAmbientPolicy.initial(owner: owner, pauseAmbientOnBattery: false)
            try policy.validate(owner: owner)
            #expect(Set(policy.subscribers.keys) == Set(jobs))
            #expect(policy.subscribers.values.allSatisfy { $0 == 0 })
            let context = try policy.context(owner: owner)
            let value = try #require(context["ambientPolicy"] as? NSDictionary)
            #expect(value["pauseAmbientOnBattery"] as? Bool == false)
        }
        for counts in [
            ["usage.limits": 1], ["usage.refresh": 1, "usage.limits": 0],
            ["usage.refresh": 0, "usage.limits": -1],
            ["usage.refresh": 0, "usage.limits": 129],
            ["usage.refresh": 0, "usage.limits": 0, "forged": 1],
        ] {
            #expect(throws: (any Error).self) {
                try HostAmbientPolicy(pauseAmbientOnBattery: true, subscribers: counts).validate(
                    owner: "usage")
            }
        }
        for raw in ["true", "0.5"] {
            let data = Data(
                "{\"pauseAmbientOnBattery\":false,\"subscribers\":{\"usage.refresh\":0,\"usage.limits\":\(raw)}}"
                    .utf8)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(HostAmbientPolicy.self, from: data)
            }
        }
        #expect(
            try HostAmbientPolicy.initial(owner: "downloads", pauseAmbientOnBattery: true).context(
                owner: "downloads"
            ).count == 0)
    }

    @Test func actualLeaseCountsAreClosedDeduplicatedAndReleased() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let owner = identity("usage")
        let first = UUID(), second = UUID()
        try coordinator.visible(presentation: first, owner: owner, job: "usage.limits")
        try coordinator.visible(presentation: first, owner: owner, job: "usage.limits")
        try coordinator.visible(presentation: second, owner: owner, job: "usage.limits")
        #expect(throws: (any Error).self) {
            try coordinator.visible(presentation: UUID(), owner: owner, job: "usage.refresh")
        }
        let applied = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers == ["usage.refresh": 0, "usage.limits": 2])
            })
        #expect(applied.applied && coordinator.current(applied, owners: [owner]))
        coordinator.release(presentation: first)
        #expect(!coordinator.current(applied, owners: [owner]))
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers["usage.limits"] == 1)
            })
        coordinator.release(owner: "usage")
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: false, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers.values.allSatisfy { $0 == 0 })
                #expect(!policy.pauseAmbientOnBattery)
            })
    }

    @Test func replacementOwnerCannotInheritRetainedVisibleDemand() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let previous = identity("herdr")
        try coordinator.visible(presentation: UUID(), owner: previous, job: "sessions.discover")
        let replacement = identity("herdr", version: "2", pid: 43, birth: "new")
        let receipt = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [replacement] },
            apply: { _, policy in
                #expect(policy.subscribers["sessions.discover"] == 0)
            })
        #expect(receipt.owners.first?.identity == replacement)
        #expect(!coordinator.current(receipt, owners: [previous]))
    }

    @Test func onlyCurrentVisibleSceneRoutesHaveLiveTopics() {
        #expect(
            HostAmbientPolicyCoordinator.topic(owner: "usage", location: "main", section: "usage")
                == "usage.limits")
        #expect(
            HostAmbientPolicyCoordinator.topic(owner: "usage", location: "home", section: "limits")
                == "usage.limits")
        #expect(
            HostAmbientPolicyCoordinator.topic(owner: "herdr", location: "main", section: nil)
                == "sessions.discover")
        #expect(
            HostAmbientPolicyCoordinator.topic(
                owner: "herdr", location: "herdr.agent", section: "herdr") == "sessions.discover")
        #expect(
            HostAmbientPolicyCoordinator.topic(
                owner: "herdr", location: "herdr.space", section: "herdr") == "sessions.discover")
        #expect(
            HostAmbientPolicyCoordinator.topic(
                owner: "attention", location: "main", section: "attention") == "attention.ingest")
        #expect(
            HostAmbientPolicyCoordinator.topic(owner: "companion", location: "main", section: nil)
                == "companion.health")
        for id in HostAmbientPolicy.jobs.keys {
            #expect(
                HostAmbientPolicyCoordinator.topic(
                    owner: id, location: "settings", section: "extension") == nil)
            #expect(
                HostAmbientPolicyCoordinator.topic(owner: id, location: "main", section: "forged")
                    == nil)
        }
        #expect(
            HostAmbientPolicyCoordinator.topic(owner: "machines", location: "main", section: nil)
                == nil)
    }

    @Test func failedActiveOwnerHasActualFailureReceiptAndAbsentOwnersDoNotStart() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let owners = [identity("usage"), identity("machines")]
        var applied: [String] = []
        let receipt = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { owners },
            apply: { owner, _ in
                applied.append(owner.id)
                if owner.id == "machines" { throw HostWorkerError.rejected }
            })
        #expect(applied == ["machines", "usage"] && !receipt.applied)
        let forged = HostAmbientPolicyReceipt(
            generation: receipt.generation,
            pauseAmbientOnBattery: receipt.pauseAmbientOnBattery,
            owners: receipt.owners.map {
                .init(identity: $0.identity, policy: $0.policy, failure: nil)
            })
        #expect(!coordinator.current(forged, owners: owners))
        #expect(coordinator.current(receipt, owners: owners))
        #expect(receipt.owners.first?.failure != nil && receipt.owners.last?.applied == true)
        let empty = try await coordinator.synchronize(
            pauseAmbientOnBattery: false, owners: { [] },
            apply: { _, _ in Issue.record("Absent worker was started") })
        #expect(empty.owners.isEmpty)
    }

    @Test func overlappingPropagationSerializesActualApplyAndRetiresOlderReceipt() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let fixture = Fixture()
        let first = Task {
            try await coordinator.synchronize(
                pauseAmbientOnBattery: true, owners: { [self.identity("herdr")] },
                apply: { _, policy in try await fixture.apply(policy) })
        }
        await fixture.started(1)
        let second = Task {
            try await coordinator.synchronize(
                pauseAmbientOnBattery: false, owners: { [self.identity("herdr")] },
                apply: { _, policy in try await fixture.apply(policy) })
        }
        await Task.yield()
        #expect(fixture.values == [true])
        fixture.finish(0)
        await fixture.started(2)
        fixture.finish(1)
        let latest = try await second.value
        do { _ = try await first.value; Issue.record("Retired receipt accepted") } catch {}
        #expect(fixture.values == [true, false])
        #expect(latest.pauseAmbientOnBattery == false && coordinator.receipt == latest)
    }

    @Test func cancellationAndSelectedBirthChangesRejectReceipt() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let fixture = Fixture()
        var owner = identity("attention")
        let read = Task {
            try await coordinator.synchronize(
                pauseAmbientOnBattery: true, owners: { [owner] },
                apply: { _, policy in try await fixture.apply(policy) })
        }
        await fixture.started(1)
        owner = identity("attention", birth: "replacement")
        fixture.finish(0)
        do { _ = try await read.value; Issue.record("Changed process receipt accepted") } catch {}
        #expect(coordinator.receipt == nil)
        let write = Task {
            try await coordinator.synchronize(
                pauseAmbientOnBattery: true, owners: { [owner] },
                apply: { _, policy in try await fixture.apply(policy) })
        }
        await fixture.started(2)
        write.cancel()
        fixture.finish(1)
        do { _ = try await write.value; Issue.record("Cancelled receipt accepted") } catch {}
        #expect(coordinator.receipt == nil)
    }

    @Test func sceneAcknowledgmentPinsVisibilityAndLateShowCannotUndoHideOrClose() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let fixture = Fixture()
        let owner = identity("herdr")
        let presentation = UUID()
        let show = Task {
            try await coordinator.updateScene(
                presentation: presentation, owner: owner, job: "sessions.discover", visible: true,
                validate: {}, validatePresented: {},
                operation: {
                    try await fixture.apply(.initial(owner: "herdr", pauseAmbientOnBattery: false))
                })
        }
        await fixture.started(1)
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers["sessions.discover"] == 0)
            })
        try await coordinator.updateScene(
            presentation: presentation, owner: owner, job: "sessions.discover", visible: false,
            validate: {}, validatePresented: {}, operation: {})
        fixture.finish(0)
        do { try await show.value; Issue.record("Late visible lease accepted") } catch {}
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers["sessions.discover"] == 0)
            })
        try await coordinator.updateScene(
            presentation: presentation, owner: owner, job: "sessions.discover", visible: true,
            validate: {}, validatePresented: {}, operation: {})
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers["sessions.discover"] == 1)
            })
        let late = Task {
            try await coordinator.updateScene(
                presentation: presentation, owner: owner, job: "sessions.discover", visible: true,
                validate: {}, validatePresented: {},
                operation: {
                    try await fixture.apply(.initial(owner: "herdr", pauseAmbientOnBattery: false))
                })
        }
        await fixture.started(2)
        coordinator.release(presentation: presentation)
        fixture.finish(1)
        do { try await late.value; Issue.record("Closed presentation lease accepted") } catch {}
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers["sessions.discover"] == 0)
            })
    }

    @Test func sceneOwnerMustValidateBeforeAndAfterAndFailureReleasesDemand() async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let owner = identity("companion")
        let presentation = UUID()
        var calls = 0
        do {
            try await coordinator.updateScene(
                presentation: presentation, owner: owner, job: "companion.health", visible: true,
                validate: { throw HostWorkerError.rejected }, validatePresented: {},
                operation: { calls += 1 })
            Issue.record("Invalid current owner accepted")
        } catch {}
        #expect(calls == 0)
        do {
            try await coordinator.updateScene(
                presentation: presentation, owner: owner, job: "companion.health", visible: true,
                validate: {}, validatePresented: { throw HostWorkerError.rejected },
                operation: { calls += 1 })
            Issue.record("Retired current owner accepted")
        } catch {}
        #expect(calls == 1)
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { [owner] },
            apply: { _, policy in
                #expect(policy.subscribers["companion.health"] == 0)
            })
    }

    @Test func checkedHostReceiptRejectsChangedCoreAndRetainsActualFailedOwner() async throws {
        let core = try corePolicy(false)
        let owner = identity("machines")
        let receipt = HostAmbientPolicyReceipt(
            generation: UUID(), pauseAmbientOnBattery: false,
            owners: [
                .init(
                    identity: owner,
                    policy: .initial(owner: "machines", pauseAmbientOnBattery: false),
                    failure: "Actual worker failure")
            ])
        var calls: [Bool] = []
        let result = try await HostBackgroundPolicyResult.checked(
            core: core, validateCore: {},
            synchronize: { value in
                calls.append(value); return receipt
            }, recheck: { core }, current: { $0 == receipt })
        #expect(
            calls == [false] && result.pauseAmbientOnBattery == false && !result.propagation.applied
        )
        #expect(result.propagation.owners.first?.failure == "Actual worker failure")
        for changed in [try corePolicy(true), try corePolicy(false, pid: 42)] {
            do {
                _ = try await HostBackgroundPolicyResult.checked(
                    core: core, validateCore: {},
                    synchronize: { _ in receipt }, recheck: { changed }, current: { _ in true })
                Issue.record("Changed Core accepted")
            } catch {}
        }
        do {
            _ = try await HostBackgroundPolicyResult.checked(
                core: core, validateCore: {},
                synchronize: { _ in receipt }, recheck: { core }, current: { _ in false })
            Issue.record("Stale worker receipt accepted")
        } catch {}
        var valid = true
        do {
            _ = try await HostBackgroundPolicyResult.checked(
                core: core,
                validateCore: { guard valid else { throw HostWorkerError.rejected } },
                synchronize: { _ in
                    valid = false; return receipt
                }, recheck: { core }, current: { _ in true })
            Issue.record("Changed Core birth accepted")
        } catch {}
    }

    @Test func actualSDKAdmissionConsumesClosedHostScalarAndLeaseCountsForAllSixOwners()
        async throws
    {
        let definitions: [String: [String: ExtensionAmbientCadence]] = [
            "usage": [
                "usage.refresh": .init(ambient: 900),
                "usage.limits": .init(ambient: 900, live: 300),
            ],
            "herdr": ["sessions.discover": .init(ambient: 30, live: 2)],
            "machines": ["machines.health": .init(ambient: 300)],
            "attention": ["attention.ingest": .init(ambient: 900, live: 900)],
            "companion": ["companion.health": .init(ambient: 60, live: 20)],
            "codeStats": ["codestats.schedule": .init(ambient: 600)],
        ]
        let coordinator = HostAmbientPolicyCoordinator()
        let owners = definitions.keys.sorted().map { identity($0) }
        let policies = definitions.mapValues { jobs in
            ExtensionAmbientPolicy(
                jobs: jobs, onBattery: { true }, constrained: { false },
                notificationCenter: NotificationCenter(), observeBatteryChanges: { _ in {} })
        }
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { owners },
            apply: { owner, context in
                let policy = try #require(policies[owner.id])
                try policy.apply(context: context.context(owner: owner.id))
                for job in definitions[owner.id]!.keys { #expect(policy.interval(for: job) == nil) }
            })
        for owner in owners {
            for job in HostAmbientPolicy.jobs[owner.id]!
            where HostAmbientPolicy.liveJobs.contains(job) {
                try coordinator.visible(presentation: UUID(), owner: owner, job: job)
            }
        }
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: true, owners: { owners },
            apply: { owner, context in
                let policy = try #require(policies[owner.id])
                try policy.apply(context: context.context(owner: owner.id))
                for (job, cadence) in definitions[owner.id]! {
                    #expect(policy.interval(for: job) == cadence.live)
                }
            })
        _ = try await coordinator.synchronize(
            pauseAmbientOnBattery: false, owners: { owners },
            apply: { owner, context in
                let policy = try #require(policies[owner.id])
                try policy.apply(context: context.context(owner: owner.id))
                for (job, cadence) in definitions[owner.id]! {
                    #expect(policy.interval(for: job) == (cadence.live ?? cadence.ambient))
                }
            })
    }

    private func corePolicy(_ value: Bool, pid: Int32 = 41) throws -> HostCoreBackgroundPolicy {
        try JSONDecoder().decode(
            HostCoreBackgroundPolicy.self,
            from: JSONSerialization.data(withJSONObject: [
                "processIdentifier": pid, "pauseAmbientOnBattery": value,
            ]))
    }

    private func identity(
        _ id: String, version: String = "1", pid: Int32 = 41, birth: String = "birth"
    ) -> HostAmbientPolicyOwner {
        .init(id: id, version: version, processIdentifier: pid, processGeneration: birth)
    }

    @MainActor private final class Fixture {
        var values: [Bool] = []
        var pending: [CheckedContinuation<Void, any Error>] = []
        var signals: [(Int, CheckedContinuation<Void, Never>)] = []
        func apply(_ policy: HostAmbientPolicy) async throws {
            values.append(policy.pauseAmbientOnBattery)
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                let ready = signals.filter { $0.0 <= pending.count }
                signals.removeAll { $0.0 <= pending.count }
                ready.forEach { $0.1.resume() }
            }
        }
        func started(_ count: Int) async {
            if pending.count >= count { return }
            await withCheckedContinuation { signals.append((count, $0)) }
        }
        func finish(_ index: Int) { pending[index].resume() }
    }
}
