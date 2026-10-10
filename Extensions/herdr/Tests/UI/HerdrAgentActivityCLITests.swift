import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrAgentActivityCLITests {
    @Test func originalStatusAndHookConsumeActualOwnedMonitorAndPane() async throws {
        let worker = fixture()
        defer { HerdrWorkOwnership.enable() }
        await worker.activity.save(.init(providers: ["claude": .init(observing: true)]))
        let event = Data(
            #"{"hook_event_name":"PreToolUse","session_id":"synthetic","tool_name":"Read","cwd":"/tmp/synthetic"}"#
                .utf8)
        let hook = try await run(
            worker, arguments: hookArguments + ["--pane", "%77"], input: event)
        #expect(hook.exitCode == 0 && hook.stdout == "{}\n" && hook.stderr.isEmpty)
        let status = try await run(worker, arguments: ["activity", "status", "--json"])
        let snapshot = try AgentPayload.decode(
            AgentActivitySnapshot.self, from: Data(status.stdout.utf8))
        let session = try #require(snapshot.sessions.first)
        #expect(session.sessionID == "synthetic" && session.pane == "%77" && session.tool == "Read")
        let table = try await run(worker, arguments: ["activity", "status"])
        #expect(
            table.stdout.contains("PROVIDER") && table.stdout.contains("synthetic"))
        #expect(table.stdout.contains("0 pending approvals"))
        await worker.activity.shutdown()
    }

    @Test func originalBoundedHookNeverBypassesProviderConsentOrIntegrationOwnership() async throws
    {
        let worker = fixture()
        defer { HerdrWorkOwnership.enable() }
        let event = Data(
            #"{"hook_event_name":"PermissionRequest","session_id":"synthetic","tool_name":"Read","tool_input":{"file_path":"/tmp/synthetic"}}"#
                .utf8)
        _ = try await run(worker, arguments: hookArguments, input: event)
        #expect(await worker.activity.service.snapshot().sessions.isEmpty)
        await worker.activity.save(.init(providers: ["claude": .init(observing: true)]))
        for (arguments, input) in [
            (["activity", "hook", "--provider", "claude", "--integration-id", "foreign"], event),
            (hookArguments, Data(repeating: 65, count: AgentActivityParser.maximumInputBytes + 1)),
            (hookArguments, Data("{".utf8)),
        ] {
            let reply = try await run(worker, arguments: arguments, input: input)
            #expect(reply.exitCode == 0 && reply.stdout == "{}\n")
            #expect(await worker.activity.service.snapshot().sessions.isEmpty)
        }
        _ = try await run(worker, arguments: hookArguments, input: event)
        let snapshot = await worker.activity.service.snapshot()
        #expect(snapshot.sessions.count == 1 && snapshot.approvals.isEmpty)
        #expect(!HerdrAgentActivityCommand.helpMessage().contains("  hook"))
        let catalog =
            try JSONSerialization.jsonObject(
                with: await worker.execute("herdr.agent.catalog", payload: Data("{}".utf8)))
            as! [String: Any]
        let help = try #require(catalog["parserHelp"] as? [String: Any])
        #expect(help["serializationVersion"] as? Int == 0)
        let root = try #require(help["command"] as? [String: Any])
        #expect((root["subcommands"] as? [[String: Any]])?.count == 1)
        let activity = try #require(
            (root["subcommands"] as? [[String: Any]])?.first {
                $0["commandName"] as? String == "activity"
            })
        let hook = try #require(
            (activity["subcommands"] as? [[String: Any]])?.first {
                $0["commandName"] as? String == "hook"
            })
        #expect(hook["shouldDisplay"] as? Bool == false)
        let routes = catalog["routes"] as! [[String: Any]]
        #expect(routes.count == 2)
        #expect(
            routes.allSatisfy { ($0["route"] as? [String])?.prefix(2) == ["agent", "activity"] })
        #expect(routes.last?["readsInput"] as? Bool == true)
        await worker.activity.shutdown()
    }

    @Test func cancellingOriginalHookStreamDrainsPendingApprovalAndNonceCannotDecide() async throws
    {
        let worker = fixture()
        defer { HerdrWorkOwnership.enable() }
        await worker.activity.save(
            .init(providers: ["claude": .init(observing: true, approvals: true)]))
        _ = await worker.activity.surfaceSnapshot()
        let streams = try ExtensionCLIStreams(owner: "herdr")
        let handle = try HerdrAgentActivityCLIContext.$monitor.withValue(worker.activity) {
            try streams.start(
                HerdrAgentCLICommand.self,
                request: .init(
                    owner: "herdr", session: UUID(),
                    request: ExtensionCLIRequest(
                        arguments: hookArguments, workingDirectory: "/tmp"), deadline: 120))
        }
        let event = Data(
            #"{"hook_event_name":"PermissionRequest","session_id":"synthetic","tool_name":"Read","tool_input":{"file_path":"/tmp/synthetic"}}"#
                .utf8)
        _ = try streams.write(.init(handle: handle, sequence: 0, data: event, end: true))
        var pending: AgentApprovalRequest?
        for _ in 0..<400 {
            pending = await worker.activity.service.snapshot().approvals.first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let request = try #require(pending)
        let forged = AgentApprovalDecision(
            token: .init(id: request.id, nonce: UUID()), choice: .allowOnce)
        #expect(await worker.activity.service.decide(forged) == false)
        try streams.cancel(handle); try streams.end(handle)
        await streams.stopAndWait()
        #expect(await worker.activity.service.snapshot().approvals.isEmpty)
        await worker.activity.shutdown()
        let disabled = try await run(worker, arguments: ["activity", "status"])
        #expect(disabled.exitCode != 0 && disabled.stdout.isEmpty && !disabled.stderr.isEmpty)
    }

    private var hookArguments: [String] {
        ["activity", "hook", "--provider", "claude", "--integration-id", "edith-surfaces"]
    }
    private func fixture() -> HerdrWorker {
        let defaults = HerdrUIDefaults()
        return HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            activity: AgentActivityMonitor(defaults: defaults), defaults: defaults,
            automaticActions: false)
    }
    private func run(_ worker: HerdrWorker, arguments: [String], input: Data = Data()) async throws
        -> ExtensionCLIReply
    {
        let payload = try JSONEncoder().encode(
            ExtensionCLIRequest(
                arguments: arguments, standardInput: input, workingDirectory: "/tmp"))
        return try JSONDecoder().decode(
            ExtensionCLIReply.self, from: await worker.execute("herdr.agent.cli", payload: payload))
    }
}
