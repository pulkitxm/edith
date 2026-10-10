import EdithExtensionSupport
import Darwin
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostExtensionSessionTests {
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
        let pid = try #require(fixture.sessions.processIdentifiers[package.id])
        await fixture.sessions.shutdown()
        #expect(kill(pid, 0) == -1)
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
        let oldPID = try #require(fixture.sessions.processIdentifiers[first.id])
        let otherPID = fixture.sessions.processIdentifiers[other.id]
        try await fixture.sessions.applyUpdate(fixture.package("1.1.0"))
        #expect(fixture.sessions.versions[first.id] == "1.1.0")
        #expect(kill(oldPID, 0) == -1)
        #expect(fixture.sessions.processIdentifiers[other.id] == otherPID)
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
        let pid = fixture.sessions.processIdentifiers["sample"]
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) { try await fixture.sessions.disable(id: "sample") }
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.sessions.pendingDisableIDs == ["sample"])
        #expect(fixture.sessions.automaticallyEnabledIDs.isEmpty)
        #expect(fixture.sessions.activeIDs.isEmpty)
        #expect(fixture.sessions.states["sample"] == .active)
        #expect(fixture.sessions.processIdentifiers["sample"] == pid)
        #expect(fixture.sessions.versions["sample"] == "1.0.0")
        try await fixture.sessions.disable(id: "sample")
        #expect(fixture.sessions.enabledIDs.isEmpty)
        #expect(fixture.sessions.processIdentifiers.isEmpty)
    }

    @Test func failedRestorationBlocksUpdatingTheRunningVersion() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let pid = fixture.sessions.processIdentifiers["sample"]
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) { try await fixture.sessions.applyUpdate(fixture.package("1.1.0")) }
        #expect(fixture.sessions.versions["sample"] == "1.0.0")
        #expect(fixture.sessions.processIdentifiers["sample"] == pid)
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(await fixture.sessions.shutdown())
    }

    @Test func quittingIsVetoedUntilRestorationSucceeds() async throws {
        let fixture = try Fixture(rejectDisable: true)
        defer { fixture.clean() }
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        let pid = fixture.sessions.processIdentifiers["sample"]
        #expect(await fixture.sessions.shutdown() == false)
        #expect(fixture.sessions.states["sample"] == .active)
        #expect(fixture.sessions.enabledIDs == ["sample"])
        #expect(fixture.sessions.processIdentifiers["sample"] == pid)
        #expect(await fixture.sessions.shutdown())
        #expect(fixture.sessions.processIdentifiers.isEmpty)
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
        let originalPID = try #require(original.sessions.processIdentifiers["sample"])
        #expect(kill(originalPID, SIGKILL) == 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while kill(originalPID, 0) == 0 {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.stillRunning }
            try await Task.sleep(for: .milliseconds(10))
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
        let pid = fixture.sessions.processIdentifiers["sample"]
        try await fixture.sessions.enable(fixture.package("1.0.0"))
        #expect(fixture.sessions.pendingDisableIDs.isEmpty)
        #expect(fixture.sessions.activeIDs == ["sample"])
        #expect(fixture.sessions.processIdentifiers["sample"] == pid)
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
        let pid = fixture.sessions.processIdentifiers["sample"]
        try await fixture.sessions.applyUpdate(fixture.package("1.1.0"))
        #expect(fixture.sessions.processIdentifiers["sample"] == pid)
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
        let recoveryPID = try #require(restarted.sessions.processIdentifiers["sample"])
        try await restarted.sessions.enable(fixture.package("1.0.0"))
        #expect(kill(recoveryPID, 0) == -1)
        #expect(restarted.sessions.processIdentifiers["sample"] != recoveryPID)
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
        let recovered = try Fixture(suite: fixture.suite, mode: "require-recovery")
        await recovered.sessions.restore(packages: ["sample": fixture.package("1.1.0")])
        #expect(recovered.sessions.pendingDisableIDs.isEmpty)
        #expect(recovered.sessions.enabledIDs.isEmpty)
        #expect(recovered.sessions.processIdentifiers.isEmpty)
    }

    @MainActor private struct Fixture {
        var sessions: HostExtensionSessions
        let suite: String
        let defaults: UserDefaults

        init(
            rejectVersion: String? = nil, rejectDisable: Bool = false,
            suite existingSuite: String? = nil, mode: String? = nil
        ) throws {
            suite = existingSuite ?? "com.pulkit.edith.tests.sessions.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            let script = try #require(
                Bundle.module.url(
                    forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.sessions",
                supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
            sessions = HostExtensionSessions(defaults: defaults) { package in
                HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [
                        script.path,
                        mode
                            ?? (package.version == rejectVersion
                                ? "reject" : rejectDisable ? "reject-disable-once" : "normal"),
                    ], requestTimeout: .seconds(2))
            }
        }

        func package(_ version: String, id: String = "sample") -> ExtensionPackage {
            ExtensionPackage(
                id: id, version: version, hostABI: HostContract.compatibility,
                downloadURL: URL(
                    string: "https://github.com/example/app/releases/download/fixture/\(id).zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        }

        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}
