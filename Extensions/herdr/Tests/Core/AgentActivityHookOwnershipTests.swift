import Foundation
import Testing

@testable import HerdrUI

@Suite struct AgentActivityHookOwnershipTests {
    @Test func suspendRestoresExactBytesAndRestartOnlyResumesKnownConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith"))
        let url = installer.configurationURL(provider: .claude, scope: .global)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\n \"theme\": \"synthetic\"\n}\n".utf8)
        try original.write(to: url)
        let files = AgentActivityHookFiles(root: root.appendingPathComponent("private"))
        _ = try await files.apply(
            installer, plan: installer.plan(provider: .claude, enabled: true), scope: .global,
            enabled: true)
        #expect(
            String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(
                "agent activity hook --provider claude"))
        let restart = AgentActivityHookFiles(root: root.appendingPathComponent("private"))
        try await restart.suspend(installer)
        #expect(try Data(contentsOf: url) == original)
        try await restart.resume(installer)
        #expect(
            String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(
                "agent activity hook --provider claude"))
        #expect(
            !FileManager.default.fileExists(
                atPath: installer.configurationURL(provider: .codex, scope: .global).path))
        try await restart.suspend(installer)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func foreignEditsSurviveCleanupAndPreventUnrequestedReinstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith"))
        let files = AgentActivityHookFiles(root: root.appendingPathComponent("private"))
        let url = installer.configurationURL(provider: .claude, scope: .global)
        _ = try await files.apply(
            installer, plan: installer.plan(provider: .claude, enabled: true), scope: .global,
            enabled: true)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["theme"] = "foreign"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try await files.suspend(installer)
        let clean = try Data(contentsOf: url)
        #expect(String(decoding: clean, as: UTF8.self).contains("foreign"))
        #expect(!String(decoding: clean, as: UTF8.self).contains("agent activity hook"))
        let changed = Data("{\"theme\":\"new-owner\"}".utf8)
        try changed.write(to: url)
        try await files.resume(installer)
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test func invalidForeignConfigurationKeepsPendingCleanupForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith"))
        let files = AgentActivityHookFiles(root: root.appendingPathComponent("private"))
        let plan = try installer.plan(provider: .claude, enabled: true)
        _ = try await files.apply(installer, plan: plan, scope: .global, enabled: true)
        try Data("invalid foreign content".utf8).write(to: plan.url)
        await #expect(throws: (any Error).self) { try await files.suspend(installer) }
        #expect(try Data(contentsOf: plan.url) == Data("invalid foreign content".utf8))
        try plan.replacement?.write(to: plan.url)
        let restarted = AgentActivityHookFiles(root: root.appendingPathComponent("private"))
        try await restarted.suspend(installer)
        #expect(!FileManager.default.fileExists(atPath: plan.url.path))
    }
}
