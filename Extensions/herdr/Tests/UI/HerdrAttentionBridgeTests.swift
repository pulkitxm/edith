import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrAttentionBridgeTests {
    @Test func forwardsExactBoundedAgentAndContextReceiptsOnlyWhileActive() async throws {
        var active = false
        var calls: [(String, Data)] = []
        let bridge = HerdrAttentionBridge(active: { active }, privateMode: { false }) {
            command, payload in
            calls.append((command, payload))
            return Data()
        }
        let agent = makeAgent("mock-agent", kind: "opencode", terminal: false)
        let terminal = makeAgent("mock-terminal", kind: "terminal", terminal: true)
        let host = HerdrHostSnapshot(
            id: "mock", name: "Synthetic", isLocal: true, herdrPresent: true, reachable: false,
            agents: [agent, terminal])
        try await bridge.forward(
            hosts: [host], focused: agent, view: "space", bundleID: "com.example.fixture")
        #expect(calls.isEmpty)
        active = true
        try await bridge.forward(
            hosts: [host], focused: agent, view: "space", bundleID: "com.example.fixture")
        #expect(calls.map(\.0) == ["attention.agents.record", "attention.context"])
        let batch = try object(calls[0].1)
        #expect(Set(batch.keys) == ["hosts"])
        let hosts = try #require(batch["hosts"] as? [[String: Any]])
        #expect(hosts[0]["reachable"] as? Bool == false)
        let agents = try #require(hosts[0]["agents"] as? [[String: Any]])
        #expect(agents.count == 2)
        #expect(
            Set(agents[0].keys) == [
                "id", "kind", "machineName", "cwd", "title", "status", "isTerminal",
            ])
        #expect(agents[0]["kind"] as? String == "OpenCode")
        #expect(agents[1]["isTerminal"] as? Bool == true)
        let context = try object(calls[1].1)
        #expect(Set(context.keys) == ["bundleID", "tags", "windowTitle"])
        #expect(context["bundleID"] as? String == "com.example.fixture")
        #expect(
            (context["tags"] as? [String: String]) == [
                "page": "herdr", "view": "space", "machine": "Synthetic", "agent": "OpenCode",
                "project": "Mock project", "session": "fixture",
            ])
        bridge.shutdown()
        try await bridge.forward(
            hosts: [host], focused: agent, view: "space", bundleID: "com.example.fixture")
        #expect(calls.count == 2)
    }
    @Test func privacyClearsPreviousObservationsAndMetadataWithoutLeakingLabels() async throws {
        var calls: [(String, Data)] = []
        let bridge = HerdrAttentionBridge(active: { true }, privateMode: { true }) {
            command, payload in
            calls.append((command, payload)); return Data()
        }
        let agent = makeAgent("private", kind: "opencode", terminal: false)
        let host = HerdrHostSnapshot(
            id: "mock", name: "Synthetic", isLocal: true, herdrPresent: true, reachable: true,
            agents: [agent])
        try await bridge.forward(
            hosts: [host], focused: agent, view: "board", bundleID: "com.example.fixture")
        #expect((try object(calls[0].1)["hosts"] as? [[String: Any]])?.isEmpty == true)
        #expect(try object(calls[1].1)["windowTitle"] as? String == "")
        #expect(
            try object(calls[1].1)["tags"] as? [String: String] == [
                "page": "herdr", "view": "board",
            ])
    }
    @Test func batchBoundsAreGlobalAndLongIdentifiersRemainStableAndDistinct() async throws {
        var payloads: [Data] = []
        let bridge = HerdrAttentionBridge(active: { true }, privateMode: { false }) {
            command, payload in
            if command == "attention.agents.record" { payloads.append(payload) }
            return Data()
        }
        let prefix = String(repeating: "😀", count: 300)
        let agents = (0..<600).map {
            makeAgent(
                prefix + String($0), kind: String(repeating: "x", count: 500), terminal: false)
        }
        let host = HerdrHostSnapshot(
            id: "mock", name: "Synthetic", isLocal: true, herdrPresent: true, reachable: true,
            agents: agents)
        try await bridge.forward(
            hosts: [host, host], focused: nil, view: "board", bundleID: "com.example.fixture")
        try await bridge.forward(
            hosts: [host, host], focused: nil, view: "board", bundleID: "com.example.fixture")
        #expect(payloads[0] == payloads[1] && payloads[0].count <= 1_048_576)
        let hosts = try #require(try object(payloads[0])["hosts"] as? [[String: Any]])
        let records = hosts.flatMap { $0["agents"] as? [[String: Any]] ?? [] }
        #expect(records.count == 512)
        let ids = records.compactMap { $0["id"] as? String }
        #expect(Set(ids).count == 512 && ids.allSatisfy { $0.utf8.count <= 256 })
        #expect(records.allSatisfy { ($0["kind"] as? String)?.utf8.count ?? 1000 <= 128 })
    }
    @Test func cancellationDrainsTheInFlightPeerAndPreventsContextAdmission() async throws {
        HerdrWorkOwnership.enable()
        var entered = false
        var cancelled = false
        var commands: [String] = []
        let bridge = HerdrAttentionBridge(active: { true }, privateMode: { false }) { command, _ in
            commands.append(command)
            entered = true
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled = true
                throw error
            }
            return Data()
        }
        _ = HerdrWorkOwnership.start {
            try? await bridge.forward(
                hosts: [], focused: nil, view: "board", bundleID: "com.example.fixture")
        }
        while !entered { await Task.yield() }
        bridge.shutdown()
        await HerdrWorkOwnership.shutdown()
        #expect(
            cancelled && commands == ["attention.agents.record"]
                && HerdrWorkOwnership.pendingCount == 0)
        HerdrWorkOwnership.enable()
    }
    private func makeAgent(_ pane: String, kind: String, terminal: Bool) -> HerdrAgent {
        .make(
            machineID: "mock", machineName: "Synthetic", machineIsLocal: true, sshTarget: nil,
            session: "fixture", pane: pane, kind: kind, status: .working, title: "Mock task",
            workspace: "Mock project", cwd: "/tmp/mock-project",
            category: terminal ? .terminal : .agent)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
