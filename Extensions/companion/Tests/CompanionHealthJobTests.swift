import Foundation
import EdithExtensionSupport
import Testing

@testable import CompanionExtension

@Suite struct CompanionHealthJobTests {
    private let endpoint = URL(string: "http://127.0.0.1:4820")!

    @Test func anUnconfiguredMemoryIsSkippedRatherThanProbed() async throws {
        let probed = Probed()
        let job = CompanionHealthJob(
            isConfigured: { false }, endpoint: { self.endpoint },
            probe: { _ in
                probed.mark()
                return CompanionHealth(ok: true, checks: [])
            }, repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = await job.run()

        #expect(snapshot.skipped)
        #expect(!snapshot.reachable)
        #expect(snapshot.endpoint.isEmpty)
        #expect(!probed.happened)
    }

    @Test func aHealthyServiceReportsItsChecks() async throws {
        let job = CompanionHealthJob(
            isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in
                CompanionHealth(
                    ok: true, degraded: false,
                    checks: [CompanionCheck(name: "postgres", ok: true, detail: "ready")])
            }, repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = await job.run()

        #expect(snapshot.reachable)
        #expect(!snapshot.degraded)
        #expect(snapshot.endpoint == endpoint.absoluteString)
        #expect(snapshot.checks.map(\.name) == ["postgres"])
        #expect(snapshot.failure == nil)
    }

    @Test func aDegradedServiceStaysReachable() async throws {
        let job = CompanionHealthJob(
            isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in
                CompanionHealth(
                    ok: true, degraded: true,
                    checks: [CompanionCheck(name: "embeddings", ok: false, detail: "queued")])
            }, repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = await job.run()

        #expect(snapshot.reachable)
        #expect(snapshot.degraded)
        #expect(snapshot.checks.first?.ok == false)
    }

    @Test func anUnreachableServiceKeepsTheFailureInsteadOfThrowing() async throws {
        let job = CompanionHealthJob(
            isConfigured: { true }, endpoint: { self.endpoint },
            probe: { _ in throw URLError(.cannotConnectToHost) },
            repair: { _ in false }, deliverOutbox: { _ in })

        let snapshot = await job.run()

        #expect(!snapshot.reachable)
        #expect(!snapshot.skipped)
        #expect(snapshot.failure?.isEmpty == false)
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
