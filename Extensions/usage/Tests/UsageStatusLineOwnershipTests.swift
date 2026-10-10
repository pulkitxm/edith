import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageStatusLineOwnershipTests {
    @Test(arguments: [nil, "printf 'synthetic previous output'"])
    func stoppingRestoresTheExactPreviousCommandAndReenableKeepsOptIn(previous: String?)
        async throws
    {
        let fixture = try Fixture(previous: previous)
        defer { fixture.remove() }
        let first = fixture.service(executable: "/fixture/first ed")
        _ = try await first.execute("usage.statusline.install", payload: Data("{}".utf8))
        let installed = try #require(ClaudeStatusLine.installedCommand(settings: fixture.settings))
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(
            (try FileManager.default.attributesOfItem(atPath: fixture.marker.path)[
                .posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await first.suspendOwnedHook()
        #expect(try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == previous)
        #expect(!ClaudeStatusLine.isOptedOut(defaults: fixture.defaults))
        let restarted = fixture.service(executable: "/fixture/second ed")
        try await restarted.resumeOwnedHook()
        #expect(
            ClaudeStatusLine.installedCommand(settings: fixture.settings)
                == ClaudeStatusLine.command(executable: "/fixture/second ed", wrapping: previous))
        #expect(ClaudeStatusLine.installedCommand(settings: fixture.settings) != installed)
        _ = try await restarted.execute("usage.statusline.remove", payload: Data("{}".utf8))
        #expect(try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == previous)
        #expect(ClaudeStatusLine.isOptedOut(defaults: fixture.defaults))
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        try await fixture.service().resumeOwnedHook()
        #expect(try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == previous)
    }

    @Test func recoveryFromAStoppedProcessRestoresOnlyItsPersistedOwnedHook() async throws {
        let fixture = try Fixture(previous: "printf synthetic")
        defer { fixture.remove() }
        _ = try await fixture.service().execute(
            "usage.statusline.install", payload: Data("{}".utf8))
        try await fixture.service().suspendOwnedHook()
        #expect(
            try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == "printf synthetic"
        )
        #expect(!ClaudeStatusLine.isInstalled(settings: fixture.settings))
    }

    @Test(arguments: [
        "printf foreign",
        "'/fixture/ed' invoke usage usage.statusline.hook --json - --raw && printf foreign",
    ])
    func foreignEditsSurviveStopResumeAndDisconnect(command: String) async throws {
        let fixture = try Fixture(previous: nil)
        defer { fixture.remove() }
        _ = try await fixture.service().execute(
            "usage.statusline.install", payload: Data("{}".utf8))
        let foreign = try fixture.write(command: command)
        try await fixture.service().suspendOwnedHook()
        try await fixture.service().resumeOwnedHook()
        _ = try await fixture.service().execute("usage.statusline.remove", payload: Data("{}".utf8))
        #expect(try Data(contentsOf: fixture.settings) == foreign)
    }

    @Test func userRemovingTheHookBeforeStopDoesNotCountAsAnOwnedSuspension() async throws {
        let fixture = try Fixture(previous: nil)
        defer { fixture.remove() }
        _ = try await fixture.service().execute(
            "usage.statusline.install", payload: Data("{}".utf8))
        _ = try fixture.write(command: nil)
        try await fixture.service().suspendOwnedHook()
        try await fixture.service().resumeOwnedHook()
        #expect(try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == nil)
    }

    @Test func explicitReconnectWrapsAForeignEditedHookAndRestoresItExactly() async throws {
        let fixture = try Fixture(previous: nil)
        defer { fixture.remove() }
        _ = try await fixture.service().execute(
            "usage.statusline.install", payload: Data("{}".utf8))
        let foreign =
            "'/fixture/ed' invoke usage usage.statusline.hook --json - --raw && printf foreign"
        _ = try fixture.write(command: foreign)
        _ = try await fixture.service().execute(
            "usage.statusline.install", payload: Data("{}".utf8))
        let installed = try #require(ClaudeStatusLine.installedCommand(settings: fixture.settings))
        #expect(ClaudeStatusLine.wrappedCommand(in: installed) == foreign)
        try await fixture.service().suspendOwnedHook()
        #expect(try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == foreign)
    }

    @Test func malformedAndOversizedMarkersCannotEditSettings() async throws {
        let fixture = try Fixture(previous: "printf foreign")
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.settings)
        for data in [Data("{}".utf8), Data(repeating: 32, count: 524_289)] {
            try data.write(to: fixture.marker)
            await #expect(throws: Error.self) { try await fixture.service().suspendOwnedHook() }
            await #expect(throws: Error.self) { try await fixture.service().resumeOwnedHook() }
            #expect(try Data(contentsOf: fixture.settings) == original)
        }
    }

    @Test func shutdownDrainsAnInFlightInstallAndRejectsFurtherActions() async throws {
        let fixture = try Fixture(previous: "printf synthetic")
        defer { fixture.remove() }
        let service = fixture.service()
        _ = try await service.execute("usage.statusline.install", payload: Data("{}".utf8))
        let lock = try UsageDataLock.acquire(at: fixture.marker.appendingPathExtension("lock"))
        defer { lock.release() }
        let install = Task {
            try await service.execute("usage.statusline.install", payload: Data("{}".utf8))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await service.activeOperationCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.activeOperationCount == 1)
        let stopping = Task { try await service.shutdown() }
        await #expect(throws: CancellationError.self) { try await install.value }
        lock.release()
        try await stopping.value
        #expect(
            try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == "printf synthetic"
        )
        await #expect(throws: Error.self) {
            try await service.execute("usage.statusline.hook", payload: Data("{}".utf8))
        }
        await #expect(throws: Error.self) { try await service.resumeOwnedHook() }
        #expect(!FileManager.default.fileExists(atPath: fixture.history.path))
    }

    @Test func failedCleanupRetainsOwnershipAndCanRetryAfterSettingsRepair() async throws {
        let fixture = try Fixture(previous: "printf synthetic")
        defer { fixture.remove() }
        let service = fixture.service()
        _ = try await service.execute("usage.statusline.install", payload: Data("{}".utf8))
        let installed = try Data(contentsOf: fixture.settings)
        try Data("{synthetic malformed settings".utf8).write(to: fixture.settings)
        await #expect(throws: Error.self) { try await service.shutdown() }
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        try installed.write(to: fixture.settings)
        try await service.shutdown()
        #expect(
            try ClaudeStatusLine.configuredCommand(settings: fixture.settings) == "printf synthetic"
        )
        try await fixture.service().resumeOwnedHook()
        #expect(ClaudeStatusLine.isInstalled(settings: fixture.settings))
    }

    private struct Fixture {
        let root: URL
        let settings: URL
        let history: URL
        let marker: URL
        let defaults: UserDefaults
        let suite: String

        init(previous: String?) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "usage-hook-owner-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            settings = root.appendingPathComponent("synthetic-settings.json")
            history = root.appendingPathComponent("synthetic-history.jsonl")
            marker = root.appendingPathComponent("claude-statusline-connection.json")
            suite = "usage-hook-owner.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            _ = try write(command: previous)
        }

        @discardableResult func write(command: String?) throws -> Data {
            var object: [String: Any] = ["model": "synthetic"]
            if let command { object["statusLine"] = ["type": "command", "command": command] }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: settings)
            return data
        }

        func service(executable: String = "/fixture/ed") -> UsageStatusLineCommands {
            UsageStatusLineCommands(
                settings: settings, history: history, executable: executable, defaults: defaults)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
