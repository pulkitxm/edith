import Foundation
import Testing

@testable import EdithKit

@Suite struct AgentActivityPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ phase: AgentActivityPhase = .working) -> AgentActivitySession {
        AgentActivitySession(
            event: AgentActivityEvent(
                provider: .claude, sessionID: "native-1", eventName: "PostToolUse", phase: phase,
                project: "/tmp/demo", receivedAt: now))
    }

    private func terminal(_ id: String, native: String? = nil, category: HerdrPaneCategory = .agent)
        -> HerdrAgent
    {
        HerdrAgent(
            id: id, machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "s", pane: id, kind: "Claude Code", status: .working,
            title: "Demo", workspace: "demo", cwd: "/tmp/demo", category: category,
            nativeSession: native.map { HerdrNativeSession(provider: "claude", value: $0) })
    }

    private func terminals(
        _ agents: [HerdrAgent], local: Bool = true, reachable: Bool = true,
        attention: [String: AgentTerminalAttentionObservation] = [:]
    )
        -> SessionsSnapshot
    {
        SessionsSnapshot(
            discoveredAt: now,
            hosts: [
                HerdrHostSnapshot(
                    id: local ? "local" : "remote", name: "Test host", isLocal: local,
                    herdrPresent: true, reachable: reachable, agents: agents)
            ], working: agents.count,
            total: agents.count, attention: attention)
    }

    @Test func localNativeIdentityCombinesSourcesWithoutGuessingFromTheDirectory() {
        let activity = AgentActivitySnapshot(sessions: [session()], refreshedAt: now)
        let matched = terminal("match", native: "native-1")
        let unrelated = terminal("other", native: "native-2")
        let presentation = AgentActivityPresentation(
            activity: activity,
            terminals: terminals([matched, unrelated, terminal("shell", category: .terminal)]),
            now: now)
        #expect(presentation.working == 2)
        #expect(presentation.rows.first { $0.id == "claude:native-1" }?.terminal?.id == "match")
        #expect(!presentation.rows.contains { $0.id == "shell" })
        let remote = AgentActivityPresentation(
            activity: activity,
            terminals: terminals([matched], local: false), now: now)
        #expect(remote.working == 2)
        let offline = AgentActivityPresentation(
            activity: activity,
            terminals: terminals([matched], reachable: false), now: now)
        #expect(offline.working == 1)
    }

    @Test func oldAttentionEvidenceCannotOverrideAFreshProviderSignal() {
        let agent = terminal("pane", native: "native-1")
        let activity = AgentActivitySnapshot(sessions: [session()], refreshedAt: now)
        let old = AgentActivityPresentation(
            activity: activity,
            terminals: terminals(
                [agent],
                attention: [
                    agent.id: AgentTerminalAttentionObservation(
                        state: .looping, checkedAt: now.addingTimeInterval(-1))
                ]), now: now)
        #expect(old.working == 1)
        let fresh = AgentActivityPresentation(
            activity: activity,
            terminals: terminals(
                [agent],
                attention: [
                    agent.id: AgentTerminalAttentionObservation(
                        state: .looping, checkedAt: now)
                ]), now: now)
        #expect(fresh.stuck == 1)
        #expect(fresh.working == 0)
    }

    @Test func quietSignalsDoNotInventAStalledSession() {
        let activity = AgentActivitySnapshot(sessions: [session()], refreshedAt: now)
        let presentation = AgentActivityPresentation(
            activity: activity,
            now: now.addingTimeInterval(7200))
        #expect(presentation.quiet == 1)
        #expect(presentation.stuck == 0)
        let revived = AgentActivityPresentation(
            activity: activity,
            terminals: terminals([terminal("pane", native: "native-1")]),
            now: now.addingTimeInterval(7200))
        #expect(revived.working == 1)
    }

    @Test func independentWidgetFiltersAndFirstSeenTimeAreRetained() {
        var child = session(.waiting)
        child.id = "claude:child"
        child.parentID = "claude:native-1"
        let activity = AgentActivitySnapshot(sessions: [session(), child], refreshedAt: now)
        var tile = SurfaceTile(.agents)
        tile.includeSubagents = false
        tile.sourceIDs = ["claude"]
        tile.agentPhases = ["working"]
        let started = now.addingTimeInterval(-120)
        let presentation = AgentActivityPresentation(
            activity: activity,
            terminals: terminals([terminal("pane")]), tile: tile, now: now,
            observedAt: ["pane": started])
        #expect(presentation.rows.count == 2)
        #expect(presentation.rows.first { $0.id == "pane" }?.startedAt == started)
        tile.sourceIDs = []
        #expect(AgentActivityPresentation(activity: activity, tile: tile, now: now).rows.isEmpty)
    }

    @Test func readableApprovalFieldsKeepExactTextAndScalarArguments() {
        let input = AgentApprovalInput(
            #"{"command":" echo one\n echo two ","timeout":30000,"optional":null,"enabled":true}"#)
        #expect(input.fields.first?.id == "command")
        #expect(input.fields.first?.value == " echo one\n echo two ")
        #expect(input.fields.first { $0.id == "optional" }?.value == "null")
        #expect(input.fields.first { $0.id == "enabled" }?.value == "true")
        #expect(input.fields.first { $0.id == "timeout" }?.value == "30000")
        #expect(AgentApprovalInput("plain text").fields.first?.value == "plain text")
    }

    @Test(arguments: [AgentActivityProvider.claude, .codex])
    func longPermissionInputRetainsWhitespaceAndAllArguments(_ provider: AgentActivityProvider)
        throws
    {
        let command = "  " + String(repeating: "x", count: 12_000) + "\nTAIL  "
        let input: [String: Any] = [
            "command": command, "timeout": 30_000, "description": "Review all arguments",
        ]
        let raw: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "s1",
            "tool_name": "Bash", "tool_input": input,
        ]
        let event = try #require(
            try AgentActivityParser.parse(
                JSONSerialization.data(withJSONObject: raw), provider: provider))
        #expect(event.detail == command)
        let detail = try #require(event.permissionInput)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
        #expect(decoded["command"] as? String == command)
        #expect(decoded["timeout"] as? Int == 30_000)
        #expect(decoded["description"] as? String == "Review all arguments")
    }
}
