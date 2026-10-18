import ArgumentParser
import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

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

    @Test(arguments: AgentActivityProvider.allCases.filter { $0 != .opencode })
    func installedShellCommandMatchesActualParserAndPreservesPaneAndInput(
        _ provider: AgentActivityProvider
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try captureExecutable(root)
        let installer = AgentActivityHookInstaller(home: root, executable: executable)
        let plan = try installer.plan(provider: provider, enabled: true)
        let replacement = try #require(plan.replacement)
        let object = try #require(
            try JSONSerialization.jsonObject(with: replacement) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        let handler: [String: Any]
        if provider == .cursor {
            handler = try #require(hooks["sessionStart"]?.first)
            #expect(handler["failClosed"] as? Bool == false)
        } else {
            handler = try #require(
                (hooks["SessionStart"]?.first?["hooks"] as? [[String: Any]])?.first)
            if provider == .gemini {
                #expect(handler["timeout"] as? Int == 5000 && handler["async"] == nil)
            }
        }
        let command = try #require(handler["command"] as? String)
        for pane: String? in [nil, "", "%77", "%88 '\" $(exit 91)\nsecond line"] {
            var environment = captureEnvironment(root)
            environment["TMUX_PANE"] = pane
            let input = Data(#"{"session_id":"synthetic","detail":"🌤"}"#.utf8)
            let reply = try execute(
                URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment, input)
            #expect(reply == Data("{}\n".utf8))
            #expect(try Data(contentsOf: root.appendingPathComponent("stdin")) == input)
            let arguments = try capturedArguments(root)
            #expect(arguments.first == "agent")
            let parsed = try #require(
                try HerdrAgentCLICommand.parseAsRoot(Array(arguments.dropFirst()))
                    as? HerdrAgentActivityHookCommand)
            #expect(
                parsed.provider == provider.rawValue && parsed.integrationID == "edith-surfaces")
            #expect(parsed.pane == (pane?.isEmpty == false ? pane : nil))
        }
    }

    @Test func originalOpenCodePluginExecutesCanonicalHookWithExactPaneAndEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try captureExecutable(root)
        let installer = AgentActivityHookInstaller(home: root, executable: executable)
        try installer.openCodePlugin.write(
            to: root.appendingPathComponent("plugin.ts"), atomically: true, encoding: .utf8)
        let harness = """
            import { EdithSurfaces } from "./plugin.ts"
            const plugin = await EdithSurfaces({ client: {}, directory: "/tmp/synthetic" } as any)
            await plugin.event!({ event: { type: "session.created", properties: { session: { id: "synthetic" } } } } as any)
            const deadline = Date.now() + 5000
            while (!(await Bun.file(Bun.env.SYNTHETIC_ARGUMENTS!).exists())) {
              if (Date.now() >= deadline) throw new Error("The owned synthetic hook did not finish.")
              await Bun.sleep(5)
            }
            """
        try harness.write(
            to: root.appendingPathComponent("run.ts"), atomically: true, encoding: .utf8)
        let bun = try #require(
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent("bun") }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        var environment = captureEnvironment(root)
        environment["TMUX_PANE"] = "%88 '\" $(exit 91)"
        _ = try execute(
            bun, ["run", root.appendingPathComponent("run.ts").path], environment, Data())
        let arguments = try capturedArguments(root)
        #expect(arguments.first == "agent")
        let parsed = try #require(
            try HerdrAgentCLICommand.parseAsRoot(Array(arguments.dropFirst()))
                as? HerdrAgentActivityHookCommand)
        #expect(parsed.provider == "opencode" && parsed.integrationID == "edith-surfaces")
        #expect(parsed.pane == environment["TMUX_PANE"])
        let event = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("stdin")))
                as? [String: Any])
        #expect(event["type"] as? String == "session.created")
        #expect(event["directory"] as? String == "/tmp/synthetic")
    }

    private func captureExecutable(_ root: URL) throws -> URL {
        let executable = root.appendingPathComponent("Edith's App $(exit 91)/Edith")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        /bin/cat > "$SYNTHETIC_INPUT"
        printf '%s\\0' "$@" > "$SYNTHETIC_ARGUMENTS"
        printf '%s\\n' '{}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func captureEnvironment(_ root: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "SYNTHETIC_ARGUMENTS": root.appendingPathComponent("argv").path,
            "SYNTHETIC_INPUT": root.appendingPathComponent("stdin").path,
        ]
    }

    private func capturedArguments(_ root: URL) throws -> [String] {
        let bytes = try Data(contentsOf: root.appendingPathComponent("argv"))
        return bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private func execute(
        _ executable: URL, _ arguments: [String], _ environment: [String: String], _ input: Data
    ) throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    @Test(arguments: AgentActivityProvider.allCases.filter { $0 != .opencode })
    func publicHookReplacementAndOptOutPreserveForeignProviderFields(
        _ provider: AgentActivityProvider
    ) throws {
        let (root, installer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = installer.configurationURL(provider: provider, scope: .global)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old: [String: Any] = [
            "type": "command",
            "command": "EDITH_PROVIDER_HOOK=edith-surfaces ed invoke herdr activity.hook."
                + provider.rawValue,
        ]
        let foreign: [String: Any] = [
            "type": "command", "command": "EDITH_PROVIDER_HOOK=foreign agent activity hook",
            "timeout": 321, "custom": "synthetic",
        ]
        let handlers: [[String: Any]] =
            provider == .cursor
            ? [old, foreign] : [["matcher": "synthetic", "hooks": [old, foreign]]]
        let original: [String: Any] = [
            "version": 1, "theme": "synthetic", "hooks": ["syntheticEvent": handlers],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        _ = try installer.apply(installer.plan(provider: provider, enabled: true))
        let installed = try Data(contentsOf: url)
        #expect(!String(decoding: installed, as: UTF8.self).contains("activity.hook."))
        #expect(!(try installer.plan(provider: provider, enabled: true).changed))
        _ = try installer.apply(installer.plan(provider: provider, enabled: false))
        let cleaned =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = try #require(cleaned["hooks"] as? [String: [[String: Any]]])
        let retained: [String: Any]
        if provider == .cursor {
            retained = try #require(hooks["syntheticEvent"]?.first)
        } else {
            let group = try #require(hooks["syntheticEvent"]?.first)
            #expect(group["matcher"] as? String == "synthetic")
            retained = try #require((group["hooks"] as? [[String: Any]])?.first)
        }
        #expect(NSDictionary(dictionary: retained).isEqual(to: foreign))
        #expect(hooks.count == 1 && cleaned["theme"] as? String == "synthetic")
        #expect(cleaned["version"] as? Int == 1)
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
            if failPoll { throw ExtensionPeerError.unavailable }
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
