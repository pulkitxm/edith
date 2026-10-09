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

    @MainActor private struct Fixture {
        let sessions: HostExtensionSessions
        let suite: String
        let defaults: UserDefaults

        init(rejectVersion: String? = nil) throws {
            suite = "com.pulkit.edith.tests.sessions.\(UUID().uuidString)"
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
                        script.path, package.version == rejectVersion ? "reject" : "normal",
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
