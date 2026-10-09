import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentObserverProviderTests {
    private func parse(_ root: [String: Any], provider: AgentActivityProvider) throws
        -> AgentActivityEvent
    {
        try #require(
            try AgentActivityParser.parse(
                JSONSerialization.data(withJSONObject: root), provider: provider))
    }

    @Test func geminiReportsLifecycleToolFailuresAndPermissionWaitsWithoutPromptText() throws {
        let cases: [(String, AgentActivityPhase)] = [
            ("SessionStart", .idle), ("BeforeAgent", .working), ("BeforeTool", .working),
            ("AfterTool", .working), ("AfterAgent", .finished), ("SessionEnd", .ended),
            ("Notification", .permission),
        ]
        for (name, phase) in cases {
            let event = try parse(
                [
                    "hook_event_name": name, "session_id": "sample-session", "cwd": "/tmp/sample",
                    "tool_name": "run_shell_command", "tool_input": ["command": "printf sample"],
                    "tool_response": ["llmContent": "discard-output"], "prompt": "discard-prompt",
                    "prompt_response": "discard-response", "transcript_path": "discard-transcript",
                    "notification_type": "ToolPermission", "message": "Approve the tool in Gemini",
                ], provider: .gemini)
            #expect(event.phase == phase)
            #expect(event.identity == "gemini:sample-session")
            #expect(!event.permissionRequest)
            #expect(event.permissionInput == nil)
            let encoded = String(decoding: try AgentPayload.encode(event), as: UTF8.self)
            for text in [
                "discard-output", "discard-prompt", "discard-response", "discard-transcript",
            ] {
                #expect(!encoded.contains(text))
            }
        }
        let failed = try parse(
            [
                "hook_event_name": "AfterTool", "session_id": "sample-session",
                "tool_name": "run_shell_command", "tool_response": ["error": "Tool failed"],
            ], provider: .gemini)
        #expect(failed.phase == .error)
        #expect(failed.detail == "Tool failed")
        #expect(AgentActivitySession(event: failed).completedTools == 0)
        let completed = try parse(
            [
                "hook_event_name": "AfterTool", "session_id": "sample-session",
                "tool_name": "read_file", "tool_response": ["error": NSNull()],
            ], provider: .gemini)
        #expect(completed.phase == .working)
        #expect(AgentActivitySession(event: completed).completedTools == 1)
    }

    @Test func cursorKeepsConversationIdentityAcrossGenerationsAndDiscardsThoughts() throws {
        var session: AgentActivitySession?
        for (name, generation) in [
            ("sessionStart", "one"), ("postToolUse", "two"), ("stop", "three"),
        ] {
            let event = try parse(
                [
                    "hook_event_name": name, "conversation_id": "conversation",
                    "session_id": "other",
                    "generation_id": generation, "workspace_roots": ["/tmp/sample-workspace"],
                    "cwd": "/tmp/other", "status": "completed", "model": "legacy-model",
                    "model_id": "sample-model", "tool_name": "Shell",
                    "tool_input": ["command": "printf sample"], "tool_output": "discard-output",
                    "user_email": "discard-email", "transcript_path": "discard-transcript",
                ], provider: .cursor)
            #expect(event.identity == "cursor:conversation")
            #expect(event.project == "/tmp/sample-workspace")
            #expect(event.model == "sample-model")
            if session == nil {
                session = AgentActivitySession(event: event)
            } else {
                session?.apply(event)
            }
        }
        #expect(session?.completedTools == 1)
        #expect(session?.phase == .finished)
        for name in ["afterAgentThought", "afterAgentResponse"] {
            let event = try parse(
                [
                    "hook_event_name": name, "conversation_id": "conversation",
                    "text": "discard-thought-or-response", "user_email": "discard-email",
                    "transcript_path": "discard-transcript",
                ], provider: .cursor)
            #expect(event.phase == .working)
            #expect(event.detail == nil)
            let encoded = String(decoding: try AgentPayload.encode(event), as: UTF8.self)
            #expect(!encoded.contains("discard-"))
        }
    }

    @Test func cursorDistinguishesPermissionDenialsInterruptsAndErrors() throws {
        for (failure, interrupted, phase) in [
            ("permission_denied", false, AgentActivityPhase.blocked), ("timeout", false, .error),
            ("error", false, .error), ("error", true, .idle),
        ] {
            let event = try parse(
                [
                    "hook_event_name": "postToolUseFailure", "conversation_id": "sample-session",
                    "tool_name": "Shell", "failure_type": failure, "is_interrupt": interrupted,
                    "error_message": "Sample tool failure",
                ], provider: .cursor)
            #expect(event.phase == phase)
            #expect(event.detail == "Sample tool failure")
            #expect(!event.permissionRequest)
            #expect(AgentActivitySession(event: event).completedTools == 0)
        }
        for (status, phase) in [
            ("completed", AgentActivityPhase.finished), ("aborted", .idle), ("error", .error),
        ] {
            #expect(
                try parse(
                    [
                        "hook_event_name": "stop", "conversation_id": "sample-session",
                        "status": status,
                    ], provider: .cursor
                ).phase == phase)
        }
    }

    @Test(arguments: [AgentActivityProvider.gemini, .cursor])
    func observersCannotCreateOrGrantPermissionRequests(_ provider: AgentActivityProvider)
        async throws
    {
        let configuration = AgentActivitySettings(providers: [
            provider.rawValue: .init(observing: true, approvals: true)
        ])
        #expect(configuration.normalized().configuration(provider).observing)
        #expect(!configuration.normalized().configuration(provider).approvals)
        let service = AgentActivityService(settings: { configuration }, listener: { true })
        var event = AgentActivityEvent(
            provider: provider, sessionID: "sample-session", eventName: "PermissionRequest",
            phase: .permission, project: "/tmp/sample")
        event.permissionRequest = true
        event.tool = "Shell"
        event.permissionInput = "printf sample"
        #expect(await service.ingest(event).token == nil)
        #expect(await service.snapshot().approvals.isEmpty)
        #expect(await service.snapshot().sessions.count == 1)
        for choice in [AgentApprovalChoice.allowOnce, .deny] {
            #expect(
                try AgentActivityHookOutput.data(provider: provider, choice: choice)
                    == Data("{}".utf8))
        }
    }

    @Test func permissionTransportStaysWithinBudgetForDeeplyNestedValidInput() throws {
        var nested: Any = "sample"
        for _ in 0..<40 {
            nested = ["child": nested, "items": Array(repeating: "sample", count: 300)]
        }
        let command = "  printf 'sample'\n\t  "
        let input = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": "sample-session",
            "tool_name": "Shell", "tool_input": ["command": command, "arguments": nested],
        ])
        #expect(input.count <= AgentActivityParser.maximumInputBytes)
        let event = try #require(try AgentActivityParser.parse(input, provider: .claude))
        #expect(event.detail == command)
        #expect(
            (event.permissionInput?.utf8.count ?? .max) <= AgentActivityParser.maximumInputBytes)
        #expect(try AgentPayload.encode(event).count <= AgentActivityParser.maximumEventBytes)
        let permissionInput = try #require(event.permissionInput)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(permissionInput.utf8)) as? [String: Any])
        #expect(parsed["command"] as? String == command)
    }

    @Test func excessiveNestingFallsBackBeforeFoundationSerialization() throws {
        let nested =
            String(repeating: "[", count: AgentActivityParser.maximumInputDepth)
            + "0" + String(repeating: "]", count: AgentActivityParser.maximumInputDepth)
        let input = Data(
            "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"sample-session\",\"tool_input\":\(nested)}"
                .utf8)
        #expect(try AgentActivityParser.parse(input, provider: .claude) == nil)
        let command = String(repeating: "{[\\\"", count: 100)
        let event = try parse(
            [
                "hook_event_name": "PermissionRequest", "session_id": "sample-session",
                "tool_input": ["command": command],
            ], provider: .claude)
        #expect(event.detail == command)
    }

    @Test func oversizedEventsNeverReachTheBridge() async {
        var event = AgentActivityEvent(
            provider: .claude, sessionID: "sample-session", eventName: "PreToolUse",
            phase: .working, project: "/tmp/sample")
        event.detail = String(repeating: "x", count: AgentActivityParser.maximumEventBytes + 1)
        let runner = AgentActivityHookRunner { _, _ in
            Issue.record("An oversized event reached the bridge.")
            return try AgentPayload.encode(AgentActivityReceipt())
        }
        #expect(await runner.run(event) == nil)
    }

    @Test func anObserverIgnoresUnexpectedApprovalReceipts() async throws {
        var event = AgentActivityEvent(
            provider: .gemini, sessionID: "sample-session", eventName: "Notification",
            phase: .permission, project: "/tmp/sample")
        event.permissionRequest = true
        event.tool = "Shell"
        let receipt = AgentActivityReceipt(request: .init(event: event, now: Date(), lifetime: 118))
        let encoded = try AgentPayload.encode(receipt)
        let runner = AgentActivityHookRunner { operation, _ in
            if operation == AgentActivityOperation.ingest { return encoded }
            Issue.record("An activity observer waited for an approval decision.")
            return try AgentPayload.encode(AgentApprovalResult(choice: .allowOnce))
        }
        #expect(await runner.run(event) == nil)
    }

    @Test func providerFiltersIncludeDetectedAndPreviouslySelectedProvidersWithoutDuplicates() {
        #expect(AgentActivityProvider.terminalKind("gemini-cli") == .gemini)
        #expect(AgentActivityProvider.terminalKind("Gemini") == .gemini)
        #expect(AgentActivityProvider.terminalKind("cursor-agent") == .cursor)
        let event = AgentActivityEvent(
            provider: .gemini, sessionID: "sample-session", eventName: "BeforeAgent",
            phase: .working, project: "/tmp/sample")
        var presentation = AgentActivityPresentation(
            activity: .init(sessions: [.init(event: event)]))
        var custom = AgentActivityRow(.init(event: event))
        custom.provider = "sample-provider"
        custom.providerTitle = "Sample Provider"
        presentation.rows.append(custom)
        let choices = presentation.providerChoices(including: ["previous-provider"])
        #expect(choices.contains { $0.id == "sample-provider" && $0.title == "Sample Provider" })
        #expect(choices.contains { $0.id == "previous-provider" })
        #expect(choices.filter { $0.id == "gemini" }.count == 1)
        #expect(Set(choices.map(\.id)).count == choices.count)
    }
}

@Suite struct AgentObserverHookInstallationTests {
    @Test(arguments: [AgentActivityProvider.gemini, .cursor], [false, true])
    func setupUsesProviderSchemaAndPreservesPolicy(_ provider: AgentActivityProvider, project: Bool)
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith's App/ed"))
        let scope: AgentActivityHookScope =
            project ? .project(root.appendingPathComponent("workspace")) : .global
        let url = installer.configurationURL(provider: provider, scope: scope)
        #expect(
            url.path.contains(provider == .gemini ? ".gemini/settings.json" : ".cursor/hooks.json"))
        let policyEvent = provider == .gemini ? "BeforeTool" : "preToolUse"
        let policy: [String: Any] = [
            "type": "command", "command": "sample-policy", "timeout": 7000,
        ]
        let policyEntries: [[String: Any]] =
            provider == .gemini ? [["matcher": "run_shell_command", "hooks": [policy]]] : [policy]
        let original = try JSONSerialization.data(withJSONObject: [
            "version": 1, "theme": "dark", "security": ["trusted": false],
            "hooks": [policyEvent: policyEntries],
        ])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        let plan = try installer.plan(provider: provider, scope: scope, enabled: true)
        let result = try installer.apply(plan)
        let backupURL = try #require(result.backupURL)
        #expect(try Data(contentsOf: backupURL) == original)
        #expect(!(try installer.plan(provider: provider, scope: scope, enabled: true).changed))
        let replacement = try #require(plan.replacement)
        let updated = try #require(
            try JSONSerialization.jsonObject(with: replacement) as? [String: Any])
        #expect(updated["theme"] as? String == "dark")
        #expect((updated["security"] as? [String: Any])?["trusted"] as? Bool == false)
        let hooks = try #require(updated["hooks"] as? [String: [[String: Any]]])
        #expect(hooks["PermissionRequest"] == nil)
        let event = provider == .gemini ? "AfterTool" : "postToolUse"
        let handlers: [[String: Any]]
        if provider == .gemini {
            handlers = try #require(hooks[event]?.first?["hooks"] as? [[String: Any]])
            #expect(handlers.first?["timeout"] as? Int == 5000)
            let ended = try #require(hooks["SessionEnd"]?.first?["hooks"] as? [[String: Any]])
            #expect(ended.first?["timeout"] as? Int == 3000)
        } else {
            handlers = try #require(hooks[event])
            #expect(handlers.first?["timeout"] as? Int == 5)
            #expect(handlers.first?["failClosed"] as? Bool == false)
            #expect(handlers.first?["hooks"] == nil)
            #expect(hooks["beforeShellExecution"] == nil)
            #expect(hooks["beforeMCPExecution"] == nil)
            #expect(hooks["subagentStart"] == nil)
            #expect(hooks["subagentStop"] == nil)
            #expect((hooks[policyEvent] as NSArray?)?.isEqual(to: policyEntries) == true)
        }
        #expect(handlers.first?["async"] == nil)
        #expect(
            (handlers.first?["command"] as? String)?.contains("--provider " + provider.rawValue)
                == true)
        _ = try installer.apply(installer.plan(provider: provider, scope: scope, enabled: false))
        let removed = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let retained = try #require(removed["hooks"] as? [String: [[String: Any]]])
        #expect(Set(retained.keys) == [policyEvent])
        #expect((retained[policyEvent] as NSArray?)?.isEqual(to: policyEntries) == true)
        #expect(removed["theme"] as? String == "dark")
        #expect(
            !String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("edith-surfaces"))
    }

    @Test(arguments: ["2", "1.5", "true", "null"])
    func cursorRejectsUnsupportedVersionsWithoutChangingConfiguration(_ version: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("ed"))
        let url = installer.configurationURL(provider: .cursor, scope: .global)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(("{\"version\":" + version + ",\"hooks\":{}}").utf8)
        try original.write(to: url)
        #expect(throws: AgentActivityHookInstallerError.self) {
            try installer.plan(provider: .cursor, enabled: true)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [AgentActivityProvider.gemini, .cursor])
    func removingAnObserverDoesNotCreateOrRewriteUnrelatedFiles(_ provider: AgentActivityProvider)
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("ed"))
        let missing = try installer.plan(provider: provider, enabled: false)
        #expect(!missing.changed)
        _ = try installer.apply(missing)
        #expect(!FileManager.default.fileExists(atPath: missing.url.path))
        try FileManager.default.createDirectory(
            at: missing.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = Data("{\"version\":1,\"theme\":\"light\"}".utf8)
        try unrelated.write(to: missing.url)
        #expect(try installer.plan(provider: provider, enabled: false).replacement == unrelated)
    }
}
