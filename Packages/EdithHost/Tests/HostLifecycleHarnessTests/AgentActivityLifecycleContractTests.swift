import Foundation
import EdithHostCore
import Testing
@testable import HostLifecycleHarness

@MainActor @Suite struct AgentActivityLifecycleContractTests {
    @Test func inertStartupRequiresExplicitOwnedPreviewBeforeInstallingTheHook() async throws {
        let worker = Worker()
        try await AgentActivityFixture.installSyntheticHook(
            invoke: worker.invoke, configuration: worker.configuration,
            readConfiguration: { worker.bytes })
        #expect(
            worker.commands == [
                "herdr.ui.hook.plan", "herdr.ui.hook.read", "herdr.ui.hook.apply",
            ])
        #expect(worker.bytes == worker.replacement)
    }

    @Test(arguments: [
        "already-active", "foreign-url", "foreign-provider", "oversize", "offset", "empty",
        "foreign-apply", "unchanged-apply", "unwritten-apply",
    ])
    func aForeignOrIncompleteHookPlanCannotClaimLifecycleSuccess(mode: String) async {
        let worker = Worker(mode: mode)
        await #expect(throws: (any Error).self) {
            try await AgentActivityFixture.installSyntheticHook(
                invoke: worker.invoke, configuration: worker.configuration,
                readConfiguration: { worker.bytes })
        }
        if ["already-active", "foreign-url", "foreign-provider", "oversize", "offset", "empty"]
            .contains(mode)
        {
            #expect(!worker.commands.contains("herdr.ui.hook.apply"))
        }
    }

    @Test(arguments: [
        "legacy-operation", "foreign-provider", "foreign-integration", "missing-marker",
        "missing-event", "empty-group", "non-command", "missing-synthetic",
    ])
    func invalidProviderConfigurationsAreRejected(mode: String) throws {
        var command = Worker.command
        switch mode {
        case "legacy-operation":
            command = command.replacingOccurrences(
                of: "agent activity hook --provider claude --integration-id edith-surfaces",
                with: "activity.hook.claude")
        case "foreign-provider":
            command = command.replacingOccurrences(of: "provider claude", with: "provider codex")
        case "foreign-integration":
            command = command.replacingOccurrences(
                of: "integration-id edith-surfaces", with: "integration-id unrelated")
        case "missing-marker":
            command = command.replacingOccurrences(
                of: "EDITH_PROVIDER_HOOK=edith-surfaces", with: "OTHER=unrelated")
        default: break
        }
        var hooks = Worker.hooks(command: command)
        if mode == "missing-event" { hooks["PermissionRequest"] = nil }
        if mode == "empty-group" { hooks["PreToolUse"] = [] }
        if mode == "non-command" {
            hooks["PreToolUse"] = [["hooks": [["type": "prompt", "command": command]]]]
        }
        var object: [String: Any] = ["synthetic": true, "hooks": hooks]
        if mode == "missing-synthetic" { object["synthetic"] = nil }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: HostWorkerError.self) {
            try AgentActivityFixture.validateSyntheticHooks(bytes)
        }
    }

    @MainActor final class Worker {
        let configuration = URL(fileURLWithPath: "/owned/synthetic/.claude/settings.json")
        let token = UUID()
        static let command =
            "set -- /owned/fixture/ed agent activity hook --provider claude --integration-id edith-surfaces; if [ -n \"${TMUX_PANE-}\" ]; then set -- \"$@\" --pane \"$TMUX_PANE\"; fi; exec /usr/bin/env EDITH_PROVIDER_HOOK=edith-surfaces \"$@\""
        static func hooks(command: String) -> [String: [[String: Any]]] {
            Dictionary(
                uniqueKeysWithValues: ["PreToolUse", "PermissionRequest", "SubagentStart"].map {
                    ($0, [["hooks": [["type": "command", "command": command]]]])
                })
        }
        let replacement = try! JSONSerialization.data(withJSONObject: [
            "synthetic": true, "hooks": Worker.hooks(command: Worker.command),
        ])
        var bytes = Data("{\n  \"synthetic\": true\n}\n".utf8)
        var commands: [String] = []
        let mode: String

        init(mode: String = "valid") {
            self.mode = mode
            if mode == "already-active" { bytes = replacement }
        }

        func invoke(_ command: String, _ payload: Data) async throws -> Data {
            commands.append(command)
            let input = try #require(
                try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            switch command {
            case "herdr.ui.hook.plan":
                #expect(input["provider"] as? String == "claude")
                #expect(input["enabled"] as? Bool == true)
                return try JSONSerialization.data(withJSONObject: [
                    "id": token.uuidString,
                    "provider": mode == "foreign-provider" ? "codex" : "claude",
                    "url": mode == "foreign-url"
                        ? "file:///foreign/settings.json"
                        : configuration.absoluteString,
                    "replacementBytes": mode == "oversize" ? 2_097_153 : replacement.count,
                ])
            case "herdr.ui.hook.read":
                #expect(input["id"] as? String == token.uuidString)
                #expect(input["offset"] as? Int == 0)
                return try JSONSerialization.data(withJSONObject: [
                    "bytes": (mode == "empty" ? Data() : replacement).base64EncodedString(),
                    "nextOffset": mode == "offset" ? replacement.count + 1 : replacement.count,
                ])
            case "herdr.ui.hook.apply":
                #expect(Set(input.keys) == ["id"])
                #expect(input["id"] as? String == token.uuidString)
                if mode != "unwritten-apply" { bytes = replacement }
                return try JSONSerialization.data(withJSONObject: [
                    "url": mode == "foreign-apply"
                        ? "file:///foreign/settings.json"
                        : configuration.absoluteString,
                    "changed": mode != "unchanged-apply",
                ])
            default: throw CocoaError(.coderInvalidValue)
            }
        }
    }
}
