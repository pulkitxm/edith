import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentProtocolTests {
    @Test func matchingVersionsAreCompatible() {
        #expect(AgentProtocolCompatibility.verdict(peer: 1, agent: 1) == .compatible)
        #expect(AgentProtocolCompatibility.verdict(peer: 1, agent: 1).hint == nil)
    }

    @Test func mismatchedVersionsNameTheStaleSide() {
        let peerOlder = AgentProtocolCompatibility.verdict(peer: 1, agent: 2)
        let agentOlder = AgentProtocolCompatibility.verdict(peer: 2, agent: 1)
        #expect(peerOlder == .peerIsOlder)
        #expect(agentOlder == .agentIsOlder)
        #expect(peerOlder.hint?.contains("Relaunch Edith") == true)
        #expect(agentOlder.hint?.contains("Restart it") == true)
    }

    @Test func peerRequirementPinsTheTeamWhenThereIsOne() {
        let signed = AgentPeerIdentity.requirement(teamIdentifier: "HDYBQ2SLGT")
        #expect(signed.contains("identifier \"com.pulkit.edith\""))
        #expect(signed.contains("anchor apple generic"))
        #expect(signed.contains("certificate leaf[subject.OU] = \"HDYBQ2SLGT\""))
    }

    @Test func peerRequirementFallsBackToIdentityForAdHocBuilds() {
        let adhoc = AgentPeerIdentity.requirement(teamIdentifier: nil)
        #expect(!adhoc.contains("anchor apple generic"))
        for identifier in AgentPeerIdentity.identifiers {
            #expect(adhoc.contains("identifier \"\(identifier)\""))
        }
    }

    @Test func everyClientIdentityIsARealBundleOrTool() {
        #expect(AgentPeerIdentity.identifiers.contains(MainApp.bundleIdentifier))
        #expect(AgentPeerIdentity.identifiers.contains(MainApp.statusBarBundleIdentifier))
        #expect(AgentPeerIdentity.identifiers.contains(AgentService.machServiceName))
    }
}

@Suite struct AgentCadenceTests {
    @Test func aLiveSubscriberOverridesTheAmbientCadence() {
        let cadence = AgentCadence.every(ambient: 900, live: 300)
        #expect(
            AgentCadenceMath.interval(for: cadence, subscribers: 1, pauseAmbient: false) == 300)
        #expect(
            AgentCadenceMath.interval(for: cadence, subscribers: 0, pauseAmbient: false) == 900)
    }

    @Test func pausingAmbientLeavesLiveWorkAlone() {
        let cadence = AgentCadence.every(ambient: 900, live: 300)
        #expect(AgentCadenceMath.interval(for: cadence, subscribers: 1, pauseAmbient: true) == 300)
        #expect(AgentCadenceMath.interval(for: cadence, subscribers: 0, pauseAmbient: true) == nil)
    }

    @Test func onDemandJobsNeverSchedule() {
        #expect(
            AgentCadenceMath.interval(
                for: .onDemand, subscribers: 3, pauseAmbient: false) == nil)
    }

    @Test func toleranceIsATenthOfTheInterval() {
        #expect(AgentCadenceMath.tolerance(for: 900) == 90)
        #expect(AgentCadenceMath.tolerance(for: 2) == 1)
    }

    @Test func everyCatalogJobNamesARegisteredAbilityOrIsCore() {
        for descriptor in AgentJobCatalog.descriptors() {
            guard let abilityID = descriptor.abilityID else { continue }
            #expect(
                ExtensionRegistry.entry(abilityID) != nil,
                "\(descriptor.id) points at ability \(abilityID), which is not registered")
        }
    }

    @Test func catalogJobIdentifiersAreUnique() {
        let ids = AgentJobCatalog.descriptors().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyCatalogJobWithALiveCadenceHasATopic() {
        for descriptor in AgentJobCatalog.descriptors() where descriptor.cadence.live != nil {
            #expect(descriptor.topic != nil, "\(descriptor.id) has a live cadence but no topic")
        }
    }
}

@Suite struct JobSchedulerTests {
    private func descriptor(
        _ id: String, cadence: AgentCadence = .onDemand, topic: AgentTopic? = .usage
    ) -> AgentJobDescriptor {
        AgentJobDescriptor(
            id: id, title: id, trigger: .timer, topic: topic, cadence: cadence)
    }

    @Test func runNowPublishesToTheJobTopic() async {
        let box = PayloadBox()
        let scheduler = JobScheduler(publish: { topic, payload in box.record(topic, payload) })
        await scheduler.register(
            AgentJob(descriptor: descriptor("usage.refresh")) { Data("hello".utf8) })

        let payload = await scheduler.runNow("usage.refresh")

        #expect(payload == Data("hello".utf8))
        #expect(box.topics == [.usage])
    }

    @Test func aFailingJobRecordsItsErrorWithoutPublishing() async {
        let box = PayloadBox()
        let scheduler = JobScheduler(publish: { topic, payload in box.record(topic, payload) })
        await scheduler.register(
            AgentJob(descriptor: descriptor("usage.refresh")) {
                throw AgentError(.failed, "collector fell over")
            })

        _ = await scheduler.runNow("usage.refresh")
        let snapshot = await scheduler.snapshots.first

        #expect(box.topics.isEmpty)
        #expect(snapshot?.lastError == "collector fell over")
        #expect(snapshot?.phase == .failed)
    }

    @Test func aDisabledJobNeverRuns() async {
        let scheduler = JobScheduler()
        await scheduler.register(
            AgentJob(descriptor: descriptor("usage.refresh"), isEnabled: { false }) {
                Data("nope".utf8)
            })

        let payload = await scheduler.runNow("usage.refresh")
        let snapshot = await scheduler.snapshots.first

        #expect(payload == nil)
        #expect(snapshot?.phase == .disabled)
    }

    @Test func subscribersRaiseAndLowerTheCadence() async {
        let scheduler = JobScheduler()
        await scheduler.register(
            AgentJob(
                descriptor: descriptor(
                    "usage.limits", cadence: .every(ambient: 900, live: 300), topic: .limits)
            ) { nil })

        await scheduler.addSubscriber(topic: .limits)
        let live = await scheduler.snapshots.first
        await scheduler.removeSubscriber(topic: .limits)
        let ambient = await scheduler.snapshots.first

        #expect(live?.subscribers == 1)
        #expect(live?.effectiveInterval == 300)
        #expect(ambient?.subscribers == 0)
        #expect(ambient?.effectiveInterval == 900)
    }

    @Test func removingMoreSubscribersThanWereAddedStaysAtZero() async {
        let scheduler = JobScheduler()
        await scheduler.register(
            AgentJob(descriptor: descriptor("usage.refresh", topic: .usage)) { nil })

        await scheduler.removeSubscriber(topic: .usage)
        await scheduler.removeSubscriber(topic: .usage)

        #expect(await scheduler.subscriberCount(topic: .usage) == 0)
    }

    @Test func aBatteryPolicyPausesTheJobWhileUnplugged() async {
        let scheduler = JobScheduler(
            power: StaticPowerSource(isOnBattery: true))
        await scheduler.register(
            AgentJob(
                descriptor: AgentJobDescriptor(
                    id: "updates.discover", title: "Updates", trigger: .timer, topic: .updates,
                    cadence: .every(ambient: 900), power: .pauseOnBattery)
            ) { nil })

        #expect(await scheduler.snapshots.first?.phase == .paused)
    }
}

private final class PayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(AgentTopic, Data)] = []

    func record(_ topic: AgentTopic, _ payload: Data) {
        lock.lock()
        recorded.append((topic, payload))
        lock.unlock()
    }

    var topics: [AgentTopic] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.0)
    }
}

@Suite struct AgentStoreTests {
    private func scratch() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentStoreTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aFreshStoreMigratesAndStampsItsVersion() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "1")

        #expect(store.schemaVersion == AgentSchema.version)
        let tables = try store.read { database in
            try String.fetchAll(
                database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("usage_day"))
        #expect(tables.contains("limits_sample"))
        #expect(tables.contains("job_run"))
    }

    @Test func aFreshStoreLeavesNoPreMigrationCopy() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "228")

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix("edith.sqlite.pre-") })
    }

    @Test func theStoreIsInWALModeAndTheAgentIsTheOnlyWriter() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "1")

        let mode = try store.read { database in
            try String.fetchOne(database, sql: "PRAGMA journal_mode")
        }

        #expect(mode == "wal")
    }

    @Test func aNewerSchemaIsRefusedInsteadOfDowngraded() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = AgentStoreLayout.storeURL(root: root)
        let store = try AgentStore(url: url, build: "1")
        try store.write { database in
            try database.execute(sql: "PRAGMA user_version = \(AgentSchema.version + 5)")
        }
        try store.close()

        #expect(throws: AgentStoreError.self) {
            _ = try AgentStore(url: url, build: "2")
        }
    }

    @Test func expiredBackupsAreTheOnesOlderThanThirtyDays() {
        let now = Date()
        let names = [
            "edith.sqlite", "edith.sqlite.pre-100", "edith.sqlite.pre-200", "unrelated.txt",
        ]
        let ages: [String: Date] = [
            "edith.sqlite.pre-100": now.addingTimeInterval(-31 * 24 * 60 * 60),
            "edith.sqlite.pre-200": now.addingTimeInterval(-2 * 24 * 60 * 60),
            "edith.sqlite": now.addingTimeInterval(-90 * 24 * 60 * 60),
        ]

        #expect(
            AgentStoreLayout.expiredBackups(in: names, now: now, ages: ages)
                == ["edith.sqlite.pre-100"])
    }

    @Test func theBackupNameCarriesTheBuildItWasWrittenBefore() {
        let url = AgentStoreLayout.backupURL(root: URL(fileURLWithPath: "/tmp"), build: "228")
        #expect(url.lastPathComponent == "edith.sqlite.pre-228")
    }
}
