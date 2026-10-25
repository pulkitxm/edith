import Darwin
import Foundation
import Testing

@testable import EdithHostCore
import HostWorkerFixtureSupport

@Suite @MainActor struct HostWorkerTests {
    @Test func identitiesRoundTripWithoutCrossingNamespaces() throws {
        for identifier in [
            "com.pulkit.edith", "com.pulkit.edith.dev.sample", "com.pulkit.edith.tests.sample",
        ] {
            let identity = try HostIdentity(
                identifier: identifier, supportDirectory: URL(fileURLWithPath: "/synthetic/support")
            )
            let bytes = try JSONSerialization.data(withJSONObject: [
                "identifier": identifier, "supportDirectory": "file:///synthetic/support",
                "extensionID": "sample", "version": "1.0.0", "theme": "accent",
                "appearance": "system", "zoom": 1.0, "recoveryOnly": false,
                "ambientPolicy": ["pauseAmbientOnBattery": false, "subscribers": [:]],
            ])
            let configuration = try JSONDecoder().decode(HostWorkerConfiguration.self, from: bytes)
            #expect(try configuration.identity().root == identity.root)
        }
    }

    @Test func workerAppearanceUsesTheHostPreferencesAndClampsZoom() throws {
        let identifier = "com.pulkit.edith.tests.appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        defaults.set("blue", forKey: "theme")
        defaults.set("dark", forKey: "appearance")
        defaults.set(2.0, forKey: "mainWindowZoom")
        let identity = try HostIdentity(
            identifier: identifier, supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let configuration = HostWorkerConfiguration(
            identity: identity, extensionID: "sample", version: "1.0.0")
        #expect(configuration.theme == "blue")
        #expect(configuration.appearance == "dark")
        #expect(configuration.zoom == 1.6)
        defaults.set(Double.nan, forKey: "mainWindowZoom")
        #expect(
            HostWorkerConfiguration(identity: identity, extensionID: "sample", version: "1.0.0")
                .zoom == 1)
    }

    @Test func partialAndMultipleFramesAreDecoded() throws {
        var frames = HostWorkerFrames()
        #expect(try frames.append(Data("first".utf8)).isEmpty)
        let decoded = try frames.append(Data("\nsecond\npartial".utf8))
        #expect(decoded.map { String(decoding: $0, as: UTF8.self) } == ["first", "second"])
        #expect(try frames.append(Data("\n".utf8)) == [Data("partial".utf8)])
    }

    @Test func excessiveAndEmptyFramesAreRejected() throws {
        var frames = HostWorkerFrames()
        #expect(throws: HostWorkerError.invalidResponse) {
            try frames.append(Data(repeating: 120, count: HostWorkerFrames.maximumBytes + 1))
        }
        var empty = HostWorkerFrames()
        #expect(throws: HostWorkerError.invalidResponse) { try empty.append(Data([10])) }
    }

    @Test func startShowAndStopReleaseTheEngine() async throws {
        let worker = try fixture("normal")
        try await worker.start()
        #expect(worker.processIdentifier == getpid())
        #expect(worker.ready)
        try await worker.show()
        try await worker.synchronize()
        #expect(try await worker.status().ok)
        try await worker.stop()
        #expect(!worker.ready)
        #expect(worker.processIdentifier == nil)
    }

    @Test(arguments: ["timeout", "reject", "wrong-version"])
    func failedStartsDoNotLeaveEnginesRunning(mode: String) async throws {
        let worker = try fixture(mode, timeout: .milliseconds(300))
        do {
            try await worker.start()
            Issue.record("A failed worker was reported ready")
        } catch {
            #expect(!worker.ready)
            #expect(worker.processIdentifier == nil)
        }
        try await worker.stop()
    }

    @Test func disablingAnUnresponsiveEngineTimesOutAndReleasesIt() async throws {
        let worker = try fixture("ignore-stop", timeout: .milliseconds(300))
        try await worker.start()
        await #expect(throws: HostWorkerError.timedOut) { try await worker.stop() }
        #expect(worker.processIdentifier == nil)
    }

    @Test func rejectedRestorationKeepsTheWorkerClosedUntilRetry() async throws {
        let worker = try fixture("reject-disable-once")
        try await worker.start()
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) { try await worker.stop() }
        #expect(!worker.ready)
        #expect(worker.processIdentifier == getpid())
        await #expect(throws: HostWorkerError.rejected) { _ = try await worker.status() }
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
    }

    @Test func restorationCancellationAndLateReplyStayClosedUntilStop() async throws {
        let worker = try fixture("late-disable")
        try await worker.start()
        let task = Task { try await worker.stop() }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!worker.ready)
        #expect(worker.processIdentifier == getpid())
        try await Task.sleep(for: .milliseconds(350))
        await #expect(throws: HostWorkerError.rejected) { _ = try await worker.status() }
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
    }

    @Test func restorationTimeoutAcceptsLateReplyWithoutReopening() async throws {
        let worker = try fixture("late-disable")
        try await worker.start()
        await #expect(throws: HostWorkerError.timedOut) {
            try await worker.prepareDisable(timeout: .milliseconds(120))
        }
        #expect(!worker.ready)
        #expect(worker.processIdentifier == getpid())
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: HostWorkerError.rejected) { _ = try await worker.status() }
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
    }

    @Test func wrongVersionCleanupAcknowledgementNeverBecomesSuccessfulStop() async throws {
        let worker = try fixture("wrong-disable-version")
        try await worker.start()
        await #expect(throws: HostWorkerError.invalidResponse) { try await worker.prepareDisable() }
        #expect(!worker.ready)
        let deadline = ContinuousClock.now + .seconds(3)
        while !worker.isStopped {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(10))
        }
        await #expect(
            throws: HostWorkerError.disableRejected("Cleanup must be retried in a recovery worker.")
        ) { try await worker.stop() }
        #expect(worker.isStopped)
        #expect(worker.requiresRecovery)
    }

    @Test func ownedNavigationIsDeliveredOnlyAfterStart() async throws {
        let worker = try fixture("navigation")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        try await worker.show()
        try await worker.synchronize()
        #expect(received == 1)
        try await worker.stop()
    }

    @Test func earlyNavigationDoesNotEnterHostRouting() async throws {
        let worker = try fixture("navigation-early")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        try await worker.synchronize()
        #expect(received == 0)
        try await worker.stop()
    }

    @Test func recoveryNavigationCannotOpenHostContent() async throws {
        let worker = try fixture("navigation")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start(recoveryOnly: true)
        try await worker.show()
        await #expect(throws: HostWorkerError.rejected) { try await worker.synchronize() }
        #expect(received == 0)
        try await worker.stop()
    }

    @Test func disablePreparationNavigationCannotOpenHostContent() async throws {
        let worker = try fixture("navigation-disable")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        try await worker.prepareDisable()
        #expect(received == 0)
        try await worker.stop()
    }

    @Test(arguments: ["navigation-wrong-id", "navigation-wrong-version"])
    func forgedNavigationTerminatesTheOwnedWorker(mode: String) async throws {
        let worker = try fixture(mode)
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        do { try await worker.show(); try await worker.synchronize() } catch {}
        let deadline = ContinuousClock.now + .seconds(2)
        while !worker.isStopped, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received == 0)
        #expect(!worker.ready)
        try #require(worker.isStopped)
        try await worker.stop()
    }

    @Test func navigationAcknowledgesOnlyAfterTheOwningReceiverAppliesTheRoute() async throws {
        let worker = try fixture("navigation-ack")
        var applied = false
        worker.didRequestNavigation = { request in
            #expect(request.extensionID == "sample")
            try await Task.sleep(for: .milliseconds(60))
            applied = true
        }
        try await worker.start()
        try await worker.show()
        #expect(applied)
        #expect(worker.ready)
        try await worker.stop()
    }

    @Test func rejectedNavigationIsAcknowledgedWithoutKillingTheWorker() async throws {
        let worker = try fixture("navigation-rejected")
        worker.didRequestNavigation = { _ in throw HostWorkerError.rejected }
        try await worker.start()
        await #expect(throws: HostWorkerError.rejected) { try await worker.show() }
        #expect(worker.ready)
        #expect(try await worker.status().ok)
        try await worker.stop()
    }

    @Test(arguments: ["navigation-cancel"])
    func cancelledNavigationCannotApplyALateRoute(mode: String) async throws {
        let worker = try fixture(mode)
        var applied = false
        worker.didRequestNavigation = { _ in
            try await Task.sleep(for: .milliseconds(120))
            applied = true
        }
        try await worker.start()
        do { try await worker.show() } catch {}
        try await Task.sleep(for: .milliseconds(180))
        #expect(!applied)
        try await worker.stop()
    }

    @Test(arguments: HostWorkerStopReason.allCases)
    func closedStopReasonSelectsQuitOnlyForOriginalLidAwake(reason: HostWorkerStopReason)
        async throws
    {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.quit-" + UUID().uuidString,
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let worker = HostWorker(
            configuration: .init(identity: identity, extensionID: "lidAwake", version: "1.0.0"),
            requestTimeout: .seconds(2),
            engine: FixtureWorkerEngine.factory(mode: "quit-policy", record: file))
        try await worker.start()
        try await worker.stop(reason: reason)
        let requests = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(HostWorkerRequest.self, from: Data($0.utf8))
        }
        #expect(
            requests.map(\.operation) == [
                reason == .applicationQuit ? "prepareApplicationQuit" : "prepareDisable", "stop",
            ])
        #expect(requests.last?.stopReason == reason)
        #expect(worker.processIdentifier == nil)
    }

    @Test func unknownStopReasonIsRejectedByDecoding() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                HostWorkerRequest.self,
                from: Data(
                    "{\"token\":\"\(UUID().uuidString)\",\"operation\":\"stop\",\"stopReason\":\"skipCleanup\"}"
                        .utf8))
        }
    }

    @Test(arguments: ["record-sync", "wrong-sync-version"])
    func trustedPolicyWireRetainsOnlyAcknowledgedConfiguration(mode: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let worker = try fixture(mode, owner: "usage", record: file)
        try await worker.start()
        let policy = HostAmbientPolicy(
            pauseAmbientOnBattery: true, subscribers: ["usage.refresh": 0, "usage.limits": 1])
        let next = worker.configuration.replacingAmbientPolicy(policy)
        if mode == "wrong-sync-version" {
            await #expect(throws: HostWorkerError.invalidResponse) {
                try await worker.synchronizeAmbientPolicy(configuration: next)
            }
            #expect(!worker.configuration.ambientPolicy.pauseAmbientOnBattery)
        } else {
            try await worker.synchronizeAmbientPolicy(configuration: next)
            #expect(worker.configuration.ambientPolicy == policy)
            try await worker.synchronize(configuration: worker.configuration)
            #expect(worker.configuration.ambientPolicy == policy)
        }
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
        let requests = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(HostWorkerRequest.self, from: Data($0.utf8))
        }
        #expect(
            requests.map(\.operation)
                == (mode == "record-sync" ? ["ambientPolicy", "synchronize"] : ["ambientPolicy"]))
        #expect(requests.allSatisfy { $0.configuration?.ambientPolicy == policy })
    }

    private func fixture(
        _ mode: String, timeout: Duration = .seconds(2), owner: String = "sample",
        record: URL? = nil
    ) throws -> HostWorker {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.workers",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        return HostWorker(
            configuration: HostWorkerConfiguration(
                identity: identity, extensionID: owner, version: "1.0.0"),
            requestTimeout: timeout,
            engine: FixtureWorkerEngine.factory(mode: mode, record: record))
    }
}
