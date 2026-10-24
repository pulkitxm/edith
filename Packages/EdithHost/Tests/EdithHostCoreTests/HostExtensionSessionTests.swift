import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore
import HostWorkerFixtureSupport

@Suite @MainActor struct HostExtensionSessionTests {
    @Test func UIExitFailureKeepsTheEngineAndDisableIntentUntilRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let worker = try #require(fixture.worker("sample"))
        fixture.sessions.willDisable = { id in
            #expect(id == "sample")
            #expect(fixture.sessions.states[id] == .stopping)
            #expect(!worker.isStopped)
            throw HostWorkerError.stillRunning
        }
        await #expect(throws: HostWorkerError.stillRunning) {
            try await fixture.sessions.disable(id: "sample")
        }
        #expect(fixture.sessions.pendingDisableIDs == ["sample"])
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.worker("sample") === worker)
        #expect(!worker.isStopped)
        var detached = false
        fixture.sessions.willDisable = { _ in
            #expect(!worker.isStopped)
            detached = true
        }
        try await fixture.sessions.disable(id: "sample")
        #expect(detached)
        #expect(worker.isStopped)
        #expect(fixture.sessions.pendingDisableIDs.isEmpty)
        #expect(fixture.sessions.enabledIDs.isEmpty)
    }

    @Test func batchDisableIntentSurvivesInterruptionBeforeAnyWorkerStops() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let packages = [
            "sample": fixture.package("1.0.0"), "other": fixture.package("1.0.0", id: "other"),
        ]
        for package in packages.values { try await fixture.sessions.enable(package) }
        fixture.sessions.requestDisable(ids: ["sample", "other", "not-installed"])
        #expect(fixture.sessions.pendingDisableIDs == ["sample", "other"])
        #expect(fixture.sessions.activeIDs.isEmpty)
        #expect(fixture.sessions.automaticallyEnabledIDs.isEmpty)
        let restarted = try Fixture(suite: fixture.suite, mode: "require-recovery")
        #expect(restarted.sessions.pendingDisableIDs == ["sample", "other"])
        await restarted.sessions.restore(packages: packages)
        #expect(restarted.sessions.pendingDisableIDs.isEmpty)
        #expect(restarted.sessions.enabledIDs.isEmpty)
        #expect(restarted.sessions.processIdentifiers.isEmpty)
        #expect(restarted.sessions.states["sample"] == .disabled)
        #expect(restarted.sessions.states["other"] == .disabled)
        #expect(await fixture.sessions.shutdown())
    }

    @Test func disabledExtensionsStartNoWorkers() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.sessions.restore(packages: ["sample": fixture.package("1.0.0")])
        #expect(fixture.sessions.processIdentifiers.isEmpty)
        #expect(fixture.sessions.enabledIDs.isEmpty)
    }

    @Test func applicationUpdatesPreserveEnabledPreferencesAndRestoreCompatibleExtensions()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let package = fixture.package("1.0.0")
        try await fixture.sessions.enable(package)
        let worker = try #require(fixture.worker(package.id))
        await fixture.sessions.shutdown()
        #expect(worker.isStopped)
        #expect(fixture.sessions.enabledIDs == [package.id])
        await fixture.sessions.restore(packages: [package.id: package])
        #expect(fixture.sessions.states[package.id] == .active)
        #expect(fixture.sessions.versions[package.id] == package.version)
        try await fixture.sessions.disable(id: package.id)
        #expect(fixture.sessions.enabledIDs.isEmpty)
        #expect(fixture.sessions.processIdentifiers.isEmpty)
    }

    @Test func updatingRestartsOnlyTheAffectedWorker() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let first = fixture.package("1.0.0")
        let other = fixture.package("1.0.0", id: "other")
        try await fixture.sessions.enable(first)
        try await fixture.sessions.enable(other)
        let oldWorker = try #require(fixture.worker(first.id))
        let otherWorker = try #require(fixture.worker(other.id))
        try await fixture.sessions.applyUpdate(fixture.package("1.1.0"))
        #expect(fixture.sessions.versions[first.id] == "1.1.0")
        #expect(oldWorker.isStopped)
        #expect(fixture.worker(first.id) !== oldWorker)
        #expect(fixture.worker(other.id) === otherWorker)
        #expect(!otherWorker.isStopped)
        await fixture.sessions.shutdown()
    }

    @Test func failedUpdatesRestoreTheLastWorkingVersion() async throws {
        let fixture = try Fixture(rejectVersion: "1.1.0")
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        await #expect(throws: HostWorkerError.rejected) {
            try await fixture.sessions.applyUpdate(fixture.package("1.1.0"))
        }
        #expect(fixture.sessions.states["sample"] == .active)
        #expect(fixture.sessions.versions["sample"] == "1.0.0")
        #expect(fixture.sessions.enabledIDs == ["sample"])
        await fixture.sessions.shutdown()
    }

    @Test func failedDisablePreservesEnabledPreferenceAndProcessUntilRetry() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let worker = fixture.worker("sample")
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) { try await fixture.sessions.disable(id: "sample") }
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.sessions.pendingDisableIDs == ["sample"])
        #expect(fixture.sessions.automaticallyEnabledIDs.isEmpty)
        #expect(fixture.sessions.activeIDs.isEmpty)
        #expect(fixture.sessions.states["sample"] == .failed)
        #expect(fixture.worker("sample") === worker)
        #expect(fixture.sessions.versions["sample"] == "1.0.0")
        try await fixture.sessions.disable(id: "sample")
        #expect(fixture.sessions.enabledIDs.isEmpty)
        #expect(fixture.sessions.processIdentifiers.isEmpty)
    }

    @Test func failedRestorationBlocksUpdatingTheRunningVersion() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let worker = fixture.worker("sample")
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) { try await fixture.sessions.applyUpdate(fixture.package("1.1.0")) }
        #expect(fixture.sessions.versions["sample"] == "1.0.0")
        #expect(fixture.worker("sample") === worker)
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(await fixture.sessions.shutdown())
    }

    @Test func quittingIsVetoedUntilRestorationSucceeds() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let worker = fixture.worker("sample")
        #expect(await fixture.sessions.shutdown() == false)
        #expect(fixture.sessions.states["sample"] == .failed)
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.worker("sample") === worker)
        #expect(await fixture.sessions.shutdown())
        #expect(fixture.sessions.processIdentifiers.isEmpty)
    }

    @Test func failedStopAcknowledgementCannotBecomeSuccessfulQuitAfterExit() async throws {
        let fixture = try Fixture(mode: "reject-stop-unless-recovery")
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        #expect(await fixture.sessions.shutdown() == false)
        #expect(fixture.sessions.processIdentifiers.isEmpty)
        #expect(fixture.sessions.pendingRecoveryIDs == ["sample"])
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.sessions.automaticallyEnabledIDs.isEmpty)
        #expect(await fixture.sessions.shutdown())
        #expect(fixture.sessions.pendingRecoveryIDs.isEmpty)
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.records.workers.last?.configuration.recoveryOnly == true)
    }

    @Test func freshSessionRestoresPendingStopBeforeNormalEnable() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        fixture.defaults.set(["sample"], forKey: "pendingStopRecoveryExtensions")
        let restarted = try Fixture(suite: fixture.suite)
        #expect(restarted.sessions.automaticallyEnabledIDs.isEmpty)
        await restarted.sessions.restore(packages: ["sample": fixture.package("1.0.0")])
        #expect(restarted.sessions.pendingRecoveryIDs.isEmpty)
        #expect(restarted.sessions.activeIDs == ["sample"])
        #expect(restarted.sessions.enabledIDs == ["sample"])
        #expect(restarted.records.workers.count == 2)
        #expect(restarted.records.workers.first?.configuration.recoveryOnly == true)
        #expect(restarted.records.workers.last?.configuration.recoveryOnly == false)
        #expect(await restarted.sessions.shutdown())
    }

    @Test func pendingDisableSurvivesFreshSessionAndRecoversWithoutNormalStartup() async throws {
        let original = try Fixture(rejectDisable: true)
        defer { original.clean() }
        try await original.sessions.enable(original.package("1.0.0"))
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) {
            try await original.sessions.disable(id: "sample")
        }
        let restarted = try Fixture(suite: original.suite, mode: "require-recovery")
        #expect(restarted.sessions.pendingDisableIDs == ["sample"])
        #expect(restarted.sessions.activeIDs.isEmpty)
        await restarted.sessions.restore(packages: ["sample": restarted.package("1.1.0")])
        #expect(restarted.sessions.pendingDisableIDs.isEmpty)
        #expect(restarted.sessions.enabledIDs.isEmpty)
        #expect(restarted.sessions.processIdentifiers.isEmpty)
        #expect(restarted.sessions.states["sample"] == .disabled)
        #expect(await original.sessions.shutdown())
        #expect(original.sessions.pendingDisableIDs.isEmpty)
    }

    @Test func failedRecoveryRetainsIntentUntilConfirmedRetry() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        fixture.defaults.set(["sample"], forKey: "pendingDisableExtensions")
        let restarted = try Fixture(rejectDisable: true, suite: fixture.suite)
        await restarted.sessions.restore(packages: ["sample": fixture.package("1.0.0")])
        #expect(restarted.sessions.pendingDisableIDs == ["sample"])
        #expect(restarted.sessions.states["sample"] == .failed)
        #expect(restarted.sessions.activeIDs.isEmpty)
        #expect(restarted.sessions.versions.isEmpty)
        #expect(!restarted.sessions.processIdentifiers.isEmpty)
        try await restarted.sessions.disable(id: "sample")
        #expect(restarted.sessions.pendingDisableIDs.isEmpty)
        #expect(restarted.sessions.enabledIDs.isEmpty)
        #expect(restarted.sessions.processIdentifiers.isEmpty)
    }

    @Test func missingPackageRetainsIntentAndManualRetryCannotDiscardIt() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        fixture.defaults.set(["sample"], forKey: "pendingDisableExtensions")
        let restarted = try Fixture(suite: fixture.suite)
        await restarted.sessions.restore(packages: [:])
        await #expect(throws: HostWorkerError.rejected) {
            try await restarted.sessions.disable(id: "sample")
        }
        #expect(restarted.sessions.pendingDisableIDs == ["sample"])
        #expect(restarted.sessions.processIdentifiers.isEmpty)
    }

    @Test func explicitManualEnableOverridesPendingIntent() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) {
            try await fixture.sessions.disable(id: "sample")
        }
        let worker = fixture.worker("sample")
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        #expect(fixture.sessions.pendingDisableIDs.isEmpty)
        #expect(fixture.sessions.activeIDs == ["sample"])
        #expect(fixture.worker("sample") !== worker)
        #expect(try #require(worker).isStopped)
        #expect(await fixture.sessions.shutdown() == false)
        #expect(await fixture.sessions.shutdown())
    }

    @Test func automaticUpdateCannotRevivePendingDisable() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) {
            try await fixture.sessions.disable(id: "sample")
        }
        let worker = fixture.worker("sample")
        try await fixture.sessions.applyUpdate(fixture.package("1.1.0"))
        #expect(fixture.worker("sample") === worker)
        #expect(fixture.sessions.versions["sample"] == "1.0.0")
        #expect(fixture.sessions.pendingDisableIDs == ["sample"])
        #expect(fixture.sessions.automaticallyEnabledIDs.isEmpty)
        #expect(await fixture.sessions.shutdown())
        #expect(fixture.sessions.pendingDisableIDs.isEmpty)
        #expect(fixture.sessions.enabledIDs.isEmpty)
    }

    @Test func pendingDisableImmediatelyWithdrawsHomeAndNotchPublication() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.surfaces." + UUID().uuidString,
            supportDirectory: directory)
        defer {
            UserDefaults(suiteName: identity.defaultsSuite)?.removePersistentDomain(
                forName: identity.defaultsSuite)
        }
        let entry = HostExtension(
            id: "sample", title: "Synthetic", symbolName: "square", category: "Tools")
        let surfaces = try HostSurfaces(
            identity: identity, entries: [entry], sessions: fixture.sessions)
        let channel = ExtensionSharedState(
            root: identity.root.appendingPathComponent("ExtensionState"),
            namespace: identity.identifier)
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        #expect(channel.values(for: "host")["surface.activeIDs"] == "[\"sample\"]")
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) {
            try await fixture.sessions.disable(id: "sample")
        }
        #expect(channel.values(for: "host")["surface.activeIDs"] == "[]")
        #expect(channel.values(for: "host")["surface.activeVersions"] == "{}")
        await #expect(throws: (any Error).self) {
            try await surfaces.requests.snapshot(
                providerID: "sample", target: .home, tile: .init(.ability("sample")))
        }
        #expect(await fixture.sessions.shutdown())
    }

    @Test func manualEnableAfterFailedRecoveryRestartsNormalWorker() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        fixture.defaults.set(["sample"], forKey: "pendingDisableExtensions")
        let restarted = try Fixture(rejectDisable: true, suite: fixture.suite)
        await restarted.sessions.restore(packages: ["sample": fixture.package("1.0.0")])
        let recoveryWorker = try #require(restarted.worker("sample"))
        try await restarted.sessions.enable(fixture.package("1.0.0"))
        #expect(recoveryWorker.isStopped)
        #expect(restarted.worker("sample") !== recoveryWorker)
        #expect(restarted.sessions.pendingDisableIDs.isEmpty)
        #expect(restarted.sessions.activeIDs == ["sample"])
        #expect(await restarted.sessions.shutdown() == false)
        #expect(await restarted.sessions.shutdown())
    }

    @Test func rejectedRecoveryStartupCannotClearDisableIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        fixture.defaults.set(["sample"], forKey: "pendingDisableExtensions")
        let rejected = try Fixture(suite: fixture.suite, mode: "require-normal")
        await rejected.sessions.restore(packages: ["sample": fixture.package("1.0.0")])
        #expect(rejected.sessions.pendingDisableIDs == ["sample"])
        #expect(rejected.sessions.enabledIDs == ["sample"])
        #expect(rejected.sessions.processIdentifiers.isEmpty)
        await #expect(throws: HostWorkerError.rejected) {
            try await rejected.sessions.disable(id: "sample")
        }
        #expect(rejected.sessions.pendingDisableIDs == ["sample"])
        #expect(rejected.records.workers.last?.requiresRecovery == true)
        #expect(rejected.records.workers.last?.isStopped == true)
        let recovered = try Fixture(suite: fixture.suite, mode: "require-recovery")
        await recovered.sessions.restore(packages: ["sample": fixture.package("1.1.0")])
        #expect(recovered.sessions.pendingDisableIDs.isEmpty)
        #expect(recovered.sessions.enabledIDs.isEmpty)
        #expect(recovered.sessions.processIdentifiers.isEmpty)
    }

    @Test func failedManualEnableCannotReuseDrainedWorkerOrDiscardPendingIntent() async throws {
        let fixture = try Fixture(mode: "reject-disable-always")
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let worker = try #require(fixture.worker("sample"))
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) {
            try await fixture.sessions.disable(id: "sample")
        }
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) {
            try await fixture.sessions.enable(fixture.package("1.0.0"))
        }
        #expect(fixture.sessions.pendingDisableIDs == ["sample"])
        #expect(fixture.sessions.activeIDs.isEmpty)
        #expect(fixture.worker("sample") === worker)
        #expect(!worker.isStopped)
    }

    @Test func manualEnableFromFreshPendingSessionFinishesRecoveryBeforeNormalStartup() async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        fixture.defaults.set(["sample"], forKey: "pendingDisableExtensions")
        let restarted = try Fixture(suite: fixture.suite)
        try await restarted.sessions.enable(fixture.package("1.0.0"))
        #expect(restarted.records.workers.count == 2)
        #expect(restarted.records.workers.first?.configuration.recoveryOnly == true)
        #expect(restarted.records.workers.first?.ready == false)
        #expect(restarted.records.workers.last?.configuration.recoveryOnly == false)
        #expect(restarted.records.workers.last?.ready == true)
        #expect(restarted.sessions.pendingDisableIDs.isEmpty)
        #expect(restarted.sessions.activeIDs == ["sample"])
        #expect(await restarted.sessions.shutdown())
    }

    @Test func startFailureDuringUpdateRetriesUntilTheExtensionIsActive() async throws {
        let fixture = try Fixture(failingWorkers: 1..<3)
        defer { fixture.clean() }
        fixture.sessions.sleep = { _ in try await Task.sleep(for: .milliseconds(50)) }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        await #expect(throws: HostWorkerError.rejected) {
            try await fixture.sessions.applyUpdate(fixture.package("1.1.0"))
        }
        #expect(fixture.sessions.states["sample"] == .failed)
        #expect(
            fixture.sessions.failureReasons["sample"]
                == HostWorkerError.rejected.errorDescription)
        try await fixture.waitUntil { fixture.sessions.states["sample"] == .active }
        #expect(fixture.sessions.failureReasons["sample"] == nil)
        #expect(fixture.sessions.failures.isEmpty)
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.sessions.processIdentifiers["sample"] != nil)
        #expect(await fixture.sessions.shutdown())
    }

    @Test func startFailureAtLaunchBacksOffThenRecoversOnTheNextTrigger() async throws {
        let fixture = try Fixture(failingWorkers: 0..<4)
        defer { fixture.clean() }
        fixture.sessions.retryDelays = Array(repeating: .milliseconds(1), count: 3)
        fixture.sessions.sleep = { _ in try await Task.sleep(for: .milliseconds(1)) }
        let package = fixture.package("1.0.0")
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        await fixture.sessions.restore(packages: ["sample": package])
        try await fixture.waitUntil { fixture.records.workers.count == 4 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.records.workers.count == 4)
        #expect(fixture.sessions.states["sample"] == .failed)
        #expect(fixture.sessions.failureReasons["sample"] != nil)
        await fixture.sessions.retryFailed(packages: ["sample": package])
        #expect(fixture.sessions.states["sample"] == .active)
        #expect(fixture.sessions.failureReasons["sample"] == nil)
        #expect(await fixture.sessions.shutdown())
    }

    @Test func shutdownCancelsPendingRetries() async throws {
        let fixture = try Fixture(failingWorkers: 0..<1)
        defer { fixture.clean() }
        fixture.sessions.sleep = { _ in try await Task.sleep(for: .milliseconds(50)) }
        fixture.defaults.set(["sample"], forKey: "enabledExtensions")
        await fixture.sessions.restore(packages: ["sample": fixture.package("1.0.0")])
        #expect(fixture.sessions.states["sample"] == .failed)
        await fixture.sessions.shutdown()
        let created = fixture.records.workers.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.records.workers.count == created)
        #expect(fixture.sessions.states["sample"] == .failed)
    }

    @MainActor private final class WorkerRecords { var workers: [HostWorker] = [] }

    @MainActor private struct Fixture {
        var sessions: HostExtensionSessions
        let suite: String
        let defaults: UserDefaults
        let records: WorkerRecords

        init(
            rejectVersion: String? = nil, rejectDisable: Bool = false,
            suite existingSuite: String? = nil, mode: String? = nil,
            failingWorkers: Range<Int> = 0..<0
        ) throws {
            suite = existingSuite ?? "com.pulkit.edith.tests.sessions.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.sessions",
                supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
            let records = WorkerRecords()
            self.records = records
            sessions = HostExtensionSessions(defaults: defaults) { package in
                let worker = HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    requestTimeout: .seconds(2),
                    engine: FixtureWorkerEngine.factory(
                        mode: failingWorkers.contains(records.workers.count)
                            ? "reject"
                            : mode
                                ?? (package.version == rejectVersion
                                    ? "reject" : rejectDisable ? "reject-disable-once" : "normal")))
                records.workers.append(worker)
                return worker
            }
        }

        func worker(_ id: String) -> HostWorker? {
            records.workers.last { $0.configuration.extensionID == id }
        }

        func package(_ version: String, id: String = "sample") -> ExtensionPackage {
            ExtensionPackage(
                id: id, version: version, hostABI: HostContract.compatibility,
                downloadURL: URL(
                    string: "https://github.com/example/app/releases/download/fixture/\(id).zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw HostWorkerError.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}
