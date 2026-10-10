import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostToolingSettingsTests {
    @Test func originalInstallRemoveAndCompletionActionsUseOwnedToolingWithoutAnExtension()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var copied = ""
        let model = HostToolingSettingsModel(
            defaults: fixture.defaults, tooling: fixture.tooling, copy: { copied = $0 })
        await model.refresh()
        #expect(model.status?.tools.linked.isEmpty == true)
        #expect(model.status?.tools.bundled == true)
        await model.perform(.installTools)
        #expect(model.outcome?.succeeded == true)
        #expect(model.status?.tools.linked == ["ed", "edith"])
        for name in ["ed", "edith"] {
            #expect(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixture.bin.appendingPathComponent(name).path)
                    == fixture.executable.path)
        }
        await model.perform(.installCompletions)
        #expect(model.outcome?.succeeded == true)
        #expect(model.status?.completions.first { $0.shell == "zsh" }?.state == "current")
        let profile = try String(
            contentsOf: fixture.home.appendingPathComponent(".zshrc"), encoding: .utf8)
        #expect(profile.contains(fixture.tooling.completionFile(.zsh).path))
        await model.perform(.copySourceLine)
        #expect(copied == model.status?.fallbackSource)
        #expect(copied.contains(fixture.home.path))
        await model.perform(.removeTools)
        #expect(model.outcome?.succeeded == true)
        #expect(model.status?.tools.linked.isEmpty == true)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.bin.appendingPathComponent("ed").path))
        #expect(FileManager.default.fileExists(atPath: fixture.tooling.completionFile(.zsh).path))
    }

    @Test func unrelatedLinksAndCompletionProfilesAreNotReportedAsSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unrelated = fixture.bin.appendingPathComponent("ed")
        try Data("unrelated".utf8).write(to: unrelated)
        let model = HostToolingSettingsModel(
            defaults: fixture.defaults, tooling: fixture.tooling, copy: { _ in })
        await model.perform(.installTools)
        #expect(model.outcome?.succeeded == false)
        #expect(model.outcome?.message.contains("not managed") == true)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "unrelated")
        let completion = fixture.tooling.completionFile(.zsh)
        try FileManager.default.createDirectory(
            at: completion.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated completion".utf8).write(to: completion)
        await model.perform(.installCompletions)
        #expect(model.outcome?.succeeded == false)
        #expect(model.outcome?.message.contains("unrelated completion") == true)
        #expect(try String(contentsOf: completion, encoding: .utf8) == "unrelated completion")
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent(".zshrc").path))
    }

    @Test func missingBundledLauncherAndMalformedStatusRemainActionableErrors() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.executable)
        let model = HostToolingSettingsModel(
            defaults: fixture.defaults, tooling: fixture.tooling, copy: { _ in })
        await model.refresh()
        #expect(model.status?.tools.bundled == false)
        #expect(model.toolSummary == "not in this build")
        await model.perform(.installTools)
        #expect(model.outcome?.succeeded == false)
        #expect(model.outcome?.message.contains("not present") == true)
        let malformed = HostToolingSettingsModel(
            defaults: fixture.defaults,
            execute: { _ in
                try ExtensionCLIReply(stdout: "{}", stderr: "", exitCode: 0)
            }, copy: { _ in })
        await malformed.refresh()
        #expect(malformed.status == nil && malformed.error != nil)
    }

    @Test func completionAutoRefreshPreservesOriginalKeyAndPersistsExplicitChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = HostToolingSettingsModel(
            defaults: fixture.defaults, tooling: fixture.tooling, copy: { _ in })
        #expect(model.autoRefresh)
        #expect(HostToolingSettingsModel.autoRefreshKey == "completionsAutoRefresh")
        model.autoRefresh = false
        #expect(fixture.defaults.object(forKey: "completionsAutoRefresh") as? Bool == false)
        let restored = HostToolingSettingsModel(
            defaults: fixture.defaults, tooling: fixture.tooling, copy: { _ in })
        #expect(!restored.autoRefresh)
    }

    @Test func cancellingLateStatusDoesNotRestoreRetiredPresentationState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = ReplyGate()
        let reply = try fixture.tooling.execute(["status", "--json"])
        let model = HostToolingSettingsModel(
            defaults: fixture.defaults,
            execute: { _ in
                await gate.wait(); return reply
            }, copy: { _ in })
        let request = Task { await model.refresh() }
        while !(await gate.waiting) { await Task.yield() }
        model.cancel()
        await gate.release()
        await request.value
        #expect(model.status == nil && !model.refreshing && model.error == nil)
    }

    private struct Fixture {
        let home: URL
        let bin: URL
        let executable: URL
        let defaults: UserDefaults
        let suite: String
        var tooling: HostToolingCLI {
            HostToolingCLI(home: home, executable: executable, directory: bin, path: [bin.path])
        }
        init() throws {
            suite = "test.edith.tooling-settings.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            home = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tooling-settings-\(UUID().uuidString)")
            bin = home.appendingPathComponent("bin")
            executable = home.appendingPathComponent("Fixture.app/Contents/Resources/ed-launcher")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: home)
        }
    }
}

private actor ReplyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
