import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing
@testable import HerdrUI

@Suite(.serialized) @MainActor struct AgentActivityOwnershipTests {
    @Test func disableDrainsActivityAndHooksThenFreshWorkerRestoresOnlyOptedInScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "activity-disable-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installer = AgentActivityHookInstaller(
            home: root, executable: root.appendingPathComponent("Edith"))
        let files = AgentActivityHookFiles(root: root.appendingPathComponent("private"))
        _ = try await files.apply(
            installer, plan: installer.plan(provider: .claude, enabled: true), scope: .global,
            enabled: true)
        let monitor = AgentActivityMonitor(defaults: defaults, hookFiles: files)
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }), activity: monitor,
            activityInstaller: installer, automaticActions: false)
        await monitor.save(.init(providers: ["claude": .init(observing: true, approvals: true)]))
        await worker.start()
        let surface = HerdrSurface(worker: worker, privacyValues: { [:] })
        _ = try await snapshot(surface, SurfaceTile(.agents))
        let pending = Task {
            try await worker.execute(
                "activity.hook.claude",
                payload: Data(
                    #"{"hook_event_name":"PermissionRequest","session_id":"synthetic","tool_name":"Read","tool_input":{"file_path":"/tmp/synthetic"}}"#
                        .utf8))
        }
        _ = try await permission(surface, SurfaceTile(.agents))
        try await worker.prepareDisable()
        _ = try? await pending.value
        #expect(worker.isStopped)
        #expect(
            !FileManager.default.fileExists(
                atPath: installer.configurationURL(provider: .claude, scope: .global).path))
        #expect(monitor.settings.configuration(.claude).approvals)
        let restarted = AgentActivityMonitor(
            defaults: defaults,
            hookFiles: AgentActivityHookFiles(root: root.appendingPathComponent("private")))
        let fresh = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }), activity: restarted,
            activityInstaller: installer, automaticActions: false)
        await fresh.start()
        #expect(
            FileManager.default.fileExists(
                atPath: installer.configurationURL(provider: .claude, scope: .global).path))
        #expect(restarted.activity.approvals.isEmpty)
        try await fresh.prepareDisable()
        #expect(
            !FileManager.default.fileExists(
                atPath: installer.configurationURL(provider: .claude, scope: .global).path))
    }

    @Test func liveProviderProjectionHonorsIndependentStatesSubagentsFieldsAndCurrentApprovals()
        async throws
    {
        let suite = "activity-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = AgentActivityMonitor(defaults: defaults)
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let worker = HerdrWorker(store: store, activity: monitor, automaticActions: false)
        await monitor.save(
            .init(providers: [
                "claude": .init(observing: true, approvals: true),
                "codex": .init(observing: true),
            ]))
        await worker.start()
        let surface = HerdrSurface(worker: worker, privacyValues: { [:] })
        var tile = SurfaceTile(.agents)
        tile.sourceIDs = ["claude"]
        _ = try await snapshot(surface, tile)
        let input = Data(
            #"{"hook_event_name":"PreToolUse","session_id":"parent","cwd":"/tmp/synthetic","tool_name":"Read"}"#
                .utf8)
        let response = try await worker.execute("activity.hook.claude", payload: input)
        #expect(String(decoding: response, as: UTF8.self) == "{}")
        _ = try await worker.execute("activity.hook.codex", payload: input)
        _ = try await worker.execute(
            "activity.hook.claude",
            payload: Data(
                #"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"child","cwd":"/tmp/synthetic"}"#
                    .utf8))
        #expect(try await snapshot(surface, tile).rows.count == 2)
        tile.includeSubagents = false
        #expect(try await snapshot(surface, tile).rows.count == 1)
        tile.agentPhases = ["waiting"]
        #expect(try await snapshot(surface, tile).rows.isEmpty)
        tile.agentPhases = nil
        let hook = Task {
            try await worker.execute(
                "activity.hook.claude",
                payload: Data(
                    #"{"hook_event_name":"PermissionRequest","session_id":"parent","tool_use_id":"request","tool_name":"Bash","tool_input":{"command":"printf synthetic"}}"#
                        .utf8))
        }
        let pending = try await permission(surface, tile)
        let allow = try #require(
            pending.rows.first { $0.field == "approvals" }?.actions.first {
                $0.title == "Allow once"
            })
        var hidden = tile
        hidden.hiddenFields.insert("approvals")
        let redacted = try await snapshot(surface, hidden)
        #expect(!redacted.rows.contains { $0.field == "approvals" })
        #expect(!redacted.metrics.contains { $0.id == "permissions" })
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: hidden), actionID: allow.id
                ).encoded(providerID: "herdr"))
        }
        tile.sourceIDs = []
        #expect(try await snapshot(surface, tile).rows.isEmpty)
        tile.sourceIDs = ["claude"]
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: .init(target: .home, tile: tile), actionID: allow.id
            ).encoded(providerID: "herdr"))
        #expect(String(decoding: try await hook.value, as: UTF8.self).contains("allow"))
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: tile), actionID: allow.id
                ).encoded(providerID: "herdr"))
        }
        await worker.shutdown()
        #expect(await monitor.service.snapshot().approvals.isEmpty)
        #expect(!monitor.isListening)
        let restored = AgentActivityMonitor(defaults: defaults)
        #expect(restored.settings.configuration(.claude).approvals)
        #expect(restored.activity.sessions.isEmpty && restored.activity.approvals.isEmpty)
        await restored.shutdown()
    }

    @Test func cancelledHookDrainsExactRequestAndInjectedDecisionCannotDispatch() async throws {
        let suite = "activity-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = AgentActivityMonitor(defaults: defaults)
        await monitor.save(.init(providers: ["claude": .init(observing: true, approvals: true)]))
        await monitor.start()
        _ = await monitor.surfaceSnapshot()
        let hook = Task {
            try await monitor.execute(
                "activity.hook.claude",
                payload: Data(
                    #"{"hook_event_name":"PermissionRequest","session_id":"parent","tool_name":"Read","tool_input":{"file_path":"/tmp/synthetic"}}"#
                        .utf8))
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await monitor.service.snapshot().approvals.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try #require(await monitor.service.snapshot().approvals.first)
        var injected = try #require(
            JSONSerialization.jsonObject(
                with: AgentPayload.encode(
                    AgentApprovalDecision(token: .init(pending), choice: .allowOnce)))
                as? [String: Any])
        injected["command"] = "printf injected"
        let injectedData = try JSONSerialization.data(withJSONObject: injected)
        await #expect(throws: ExtensionPeerError.self) {
            try await monitor.execute("activity.decide", payload: injectedData)
        }
        hook.cancel()
        _ = try await hook.value
        #expect(await monitor.service.snapshot().approvals.isEmpty)
        await monitor.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await monitor.execute("activity.status", payload: Data("{}".utf8))
        }
    }

    private func snapshot(_ surface: HerdrSurface, _ tile: SurfaceTile) async throws
        -> SurfaceSnapshot
    {
        try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "herdr")), providerID: "herdr")
    }
    private func permission(_ surface: HerdrSurface, _ tile: SurfaceTile) async throws
        -> SurfaceSnapshot
    {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            let value = try await snapshot(surface, tile)
            if value.metrics.first { $0.id == "permissions" }?.value == "1" { return value }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        throw ExtensionPeerError.unavailable
    }
}
