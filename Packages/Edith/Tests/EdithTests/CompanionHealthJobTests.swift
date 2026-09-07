import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct CompanionHealthJobTests {
    private let endpoint = URL(string: "http://127.0.0.1:4820")!

    @Test func anUnconfiguredMemoryIsSkippedRatherThanProbed() async throws {
        let probed = Probed()
        let job = CompanionHealthJob(
            store: nil, isConfigured: { false }, endpoint: { self.endpoint },
            probe: { _ in
                probed.mark()
                return CompanionHealth(ok: true, checks: [])
            }, repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = try decode(await job.run())

        #expect(snapshot.skipped)
        #expect(!snapshot.reachable)
        #expect(snapshot.endpoint.isEmpty)
        #expect(!probed.happened)
    }

    @Test func aHealthyServiceReportsItsChecks() async throws {
        let job = CompanionHealthJob(
            store: nil, isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in
                CompanionHealth(
                    ok: true, degraded: false,
                    checks: [CompanionCheck(name: "postgres", ok: true, detail: "ready")])
            }, repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = try decode(await job.run())

        #expect(snapshot.reachable)
        #expect(!snapshot.degraded)
        #expect(snapshot.endpoint == endpoint.absoluteString)
        #expect(snapshot.checks.map(\.name) == ["postgres"])
        #expect(snapshot.failure == nil)
    }

    @Test func aDegradedServiceStaysReachable() async throws {
        let job = CompanionHealthJob(
            store: nil, isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in
                CompanionHealth(
                    ok: true, degraded: true,
                    checks: [CompanionCheck(name: "embeddings", ok: false, detail: "queued")])
            }, repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = try decode(await job.run())

        #expect(snapshot.reachable)
        #expect(snapshot.degraded)
        #expect(snapshot.checks.first?.ok == false)
    }

    @Test func anUnreachableServiceKeepsTheFailureInsteadOfThrowing() async throws {
        let job = CompanionHealthJob(
            store: nil, isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in throw URLError(.cannotConnectToHost) },
            repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = try decode(await job.run())

        #expect(!snapshot.reachable)
        #expect(!snapshot.skipped)
        #expect(snapshot.failure?.isEmpty == false)
    }

    @Test func theJobRunsEveryTwentySecondsWhileWatchedAndEveryMinuteOtherwise() throws {
        let descriptor = try #require(
            AgentJobPlan.descriptors.first { $0.id == "companion.health" })

        #expect(descriptor.cadence == .every(ambient: 60, live: 20))
        #expect(descriptor.abilityID == "companion")
        #expect(descriptor.topic == .companion)
    }

    @Test func theCatalogRunsTheJob() async throws {
        let bodies = AgentJobCatalog.collectors(store: nil)
        #expect(bodies["companion.health"] != nil)
    }

    private func decode(_ data: Data?) throws -> CompanionHealthSnapshot {
        try AgentPayload.decode(CompanionHealthSnapshot.self, from: try #require(data))
    }
}

private final class Probed: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var happened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
