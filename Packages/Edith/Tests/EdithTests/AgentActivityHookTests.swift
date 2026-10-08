import Foundation
import Testing

@testable import EdithKit

@Suite struct AgentActivityHookInstallerTests {
    private func fixture() throws -> (URL, AgentActivityHookInstaller) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root,
            AgentActivityHookInstaller(
                home: root, executable: root.appendingPathComponent("Edith's App/ed"))
        )
    }

    @Test(arguments: [AgentActivityProvider.claude, .codex])
    func installationPreservesUserHooksAndBacksUpTheExactOriginal(_ provider: AgentActivityProvider)
        throws
    {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = installer.configurationURL(provider: provider, scope: .global)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(
            #"{"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-policy"}]}]}}"#
                .utf8)
        try original.write(to: url)
        let plan = try installer.plan(provider: provider, enabled: true)
        let installation = try installer.apply(plan)
        let backup = try #require(installation.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(
            try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
                == 0o600)
        let data = try #require(plan.replacement)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["theme"] as? String == "dark")
        #expect(String(decoding: data, as: UTF8.self).contains("my-policy"))
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        let permission = try #require(
            hooks["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])
        #expect(permission.first?["async"] == nil)
        #expect(permission.first?["timeout"] as? Int == 120)
        #expect((permission.first?["command"] as? String)?.contains("'\\''") == true)
        #expect(!(try installer.plan(provider: provider, enabled: true).changed))
        let removal = try installer.plan(provider: provider, enabled: false)
        _ = try installer.apply(removal)
        let retained = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(retained.contains("my-policy"))
        #expect(retained.contains("theme"))
        #expect(!retained.contains("edith-surfaces"))
    }

    @Test func stalePreviewCannotOverwriteAConcurrentConfigurationEdit() throws {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installer.plan(provider: .claude, enabled: true)
        try FileManager.default.createDirectory(
            at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let edited = Data(#"{"newSetting":true}"#.utf8)
        try edited.write(to: plan.url)
        #expect(throws: AgentActivityHookInstallerError.self) { try installer.apply(plan) }
        #expect(try Data(contentsOf: plan.url) == edited)
    }

    @Test func removalDoesNotCreateOrReformatAnUnrelatedConfiguration() throws {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try installer.plan(provider: .codex, enabled: false)
        #expect(!missing.changed)
        _ = try installer.apply(missing)
        #expect(!FileManager.default.fileExists(atPath: missing.url.path))
        try FileManager.default.createDirectory(
            at: missing.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"hooks":{},"theme":"light"}"#.utf8)
        try original.write(to: missing.url)
        #expect(try installer.plan(provider: .codex, enabled: false).replacement == original)
    }

    @Test func malformedConfigurationAndUnrelatedPluginsAreLeftAlone() throws {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = installer.configurationURL(provider: .claude, scope: .global)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"hooks":{"Stop":"custom-invalid-shape"}}"#.utf8)
        try original.write(to: url)
        #expect(throws: AgentActivityHookInstallerError.self) {
            try installer.plan(provider: .claude, enabled: true)
        }
        #expect(try Data(contentsOf: url) == original)
        let plugin = installer.configurationURL(provider: .opencode, scope: .global)
        try FileManager.default.createDirectory(
            at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = Data("export const MyPlugin = () => ({})".utf8)
        try unrelated.write(to: plugin)
        #expect(throws: AgentActivityHookInstallerError.self) {
            try installer.plan(provider: .opencode, enabled: true)
        }
        #expect(try Data(contentsOf: plugin) == unrelated)
    }

    @Test func projectAndGlobalPathsStayIndependent() throws {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let local = installer.configurationURL(provider: .opencode, scope: .project(project))
        #expect(
            local.path == project.appendingPathComponent(".opencode/plugins/edith-surfaces.ts").path
        )
        #expect(local != installer.configurationURL(provider: .opencode, scope: .global))
        let plan = try installer.plan(provider: .opencode, scope: .project(project), enabled: true)
        _ = try installer.apply(plan)
        #expect(
            !(try installer.plan(provider: .opencode, scope: .project(project), enabled: true)
                .changed))
        let removal = try installer.plan(
            provider: .opencode, scope: .project(project), enabled: false)
        _ = try installer.apply(removal)
        #expect(!FileManager.default.fileExists(atPath: local.path))
    }

    @Test func openCodePluginUsesTheAuthenticatedClientAndNeverAnAlwaysGrant() throws {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = installer.openCodePlugin
        #expect(plugin.contains("client.postSessionIdPermissionsPermissionId"))
        #expect(plugin.contains("void forward(event)"))
        #expect(plugin.contains("active.get(properties.requestID)?.kill()"))
        #expect(!plugin.contains("fetch("))
        #expect(!plugin.contains("\"always\""))
        #expect(plugin.contains("new Blob([JSON.stringify"))
    }
}

private actor ActivityHookTransport {
    var operations: [String] = []
    let token = AgentApprovalToken(id: UUID(), nonce: UUID())
    var failPoll = false
    func perform(_ operation: String, _ data: Data) throws -> Data {
        operations.append(operation)
        if operation == AgentActivityOperation.ingest {
            var receipt = AgentActivityReceipt()
            receipt.token = token
            receipt.expiresAt = Date().addingTimeInterval(30)
            return try AgentPayload.encode(receipt)
        }
        if operation == AgentActivityOperation.poll {
            if failPoll { throw AgentError.unavailable }
            return try AgentPayload.encode(AgentApprovalResult(choice: .deny))
        }
        return Data()
    }
    func setFailure() { failPoll = true }
}

@Suite struct AgentActivityHookRunnerTests {
    @Test func permissionReturnsOnlyTheExactDecisionAndObserversNeverWait() async {
        let transport = ActivityHookTransport()
        let runner = AgentActivityHookRunner { try await transport.perform($0, $1) }
        var event = AgentActivityEvent(
            provider: .claude, sessionID: "s1", eventName: "PermissionRequest", phase: .permission,
            project: "/tmp/demo")
        event.permissionRequest = true
        #expect(await runner.run(event) == .deny)
        #expect(
            await transport.operations == [
                AgentActivityOperation.ingest, AgentActivityOperation.poll,
            ])
        let observer = ActivityHookTransport()
        event.permissionRequest = false
        #expect(
            await AgentActivityHookRunner { try await observer.perform($0, $1) }.run(event) == nil)
        #expect(await observer.operations == [AgentActivityOperation.ingest])
    }

    @Test func transportFailureCancelsTheRequestWithoutReturningAnApproval() async {
        let transport = ActivityHookTransport()
        await transport.setFailure()
        var event = AgentActivityEvent(
            provider: .codex, sessionID: "s1", eventName: "PermissionRequest", phase: .permission,
            project: "/tmp/demo")
        event.permissionRequest = true
        #expect(
            await AgentActivityHookRunner { try await transport.perform($0, $1) }.run(event) == nil)
        #expect(
            await transport.operations == [
                AgentActivityOperation.ingest, AgentActivityOperation.poll,
                AgentActivityOperation.cancel,
            ])
    }
}
