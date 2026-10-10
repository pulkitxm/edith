import EdithExtensionSupport
import EdithHostCore
import Foundation

enum AgentActivityFixture {
    static func seed(identity: HostIdentity) throws {
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil,
            let defaults = UserDefaults(suiteName: identity.extensionDefaultsSuite("herdr"))
        else { throw HostWorkerError.rejected }
        let settings: [String: Any] = [
            "providers": [
                "claude": ["observing": true, "approvals": true],
                "codex": ["observing": true, "approvals": false],
            ], "quietMinutes": 10, "monitorTerminalAttention": false,
        ]
        defaults.set(
            String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self),
            forKey: "agentActivityProviders")
        guard let home = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] else {
            throw HostWorkerError.rejected
        }
        let config = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        let original = Data("{\n  \"synthetic\": true\n}\n".utf8)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: config)
        let directory = identity.extensionDirectory("herdr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "provider": "claude", "original": original.base64EncodedString(), "consent": true,
            "active": false,
        ]
        try JSONSerialization.data(withJSONObject: [record]).write(
            to: directory.appendingPathComponent("provider-hook-ownership.json"))
    }

    static func verifyHooks(active: Bool) throws {
        guard let home = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] else {
            throw HostWorkerError.rejected
        }
        let config = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        let bytes = try Data(contentsOf: config)
        if active {
            guard String(decoding: bytes, as: UTF8.self).contains("activity.hook.claude") else {
                throw HostWorkerError.invalidResponse
            }
        } else {
            guard bytes == Data("{\n  \"synthetic\": true\n}\n".utf8) else {
                throw HostWorkerError.invalidResponse
            }
        }
    }

    @MainActor static func verify(_ endpoint: ExtensionPeerEndpoint) async throws {
        try verifyHooks(active: true)
        var tile = SurfaceTile(.agents)
        tile.sourceIDs = ["claude"]
        tile.includeSubagents = false
        tile.itemLimit = 10
        let status = try await object(endpoint, "activity.status", Data("{}".utf8))
        guard let settings = status["settings"] as? [String: Any],
            let providers = settings["providers"] as? [String: Any],
            (providers["claude"] as? [String: Any])?["approvals"] as? Bool == true,
            (status["approvals"] as? [Any])?.isEmpty == true
        else { throw HostWorkerError.invalidResponse }
        _ = try await snapshot(endpoint, tile)
        for (provider, input) in [
            (
                "claude",
                #"{"hook_event_name":"PreToolUse","session_id":"synthetic-parent","cwd":"/tmp/synthetic-provider","tool_name":"Read"}"#
            ),
            (
                "claude",
                #"{"hook_event_name":"SubagentStart","session_id":"synthetic-parent","agent_id":"synthetic-child","cwd":"/tmp/synthetic-provider"}"#
            ),
            (
                "codex",
                #"{"hook_event_name":"PreToolUse","session_id":"synthetic-other","cwd":"/tmp/synthetic-provider"}"#
            ),
        ] {
            let response = try await endpoint.invoke(
                "activity.hook." + provider, payload: Data(input.utf8))
            guard try JSONSerialization.jsonObject(with: response) as? [String: String] == [:]
            else {
                throw HostWorkerError.invalidResponse
            }
        }
        let filtered = try await snapshot(endpoint, tile)
        guard filtered.sources.contains(where: { $0.id == "claude" }), filtered.rows.count == 1,
            filtered.rows.allSatisfy({ $0.sourceID == "claude" }),
            filtered.metrics.first(where: { $0.id == "running" })?.value == "1"
        else { throw HostWorkerError.invalidResponse }
        tile.includeSubagents = true
        guard try await snapshot(endpoint, tile).rows.count == 2 else {
            throw HostWorkerError.invalidResponse
        }
        tile.agentPhases = ["permission"]
        guard try await snapshot(endpoint, tile).rows.isEmpty else {
            throw HostWorkerError.invalidResponse
        }
        tile.agentPhases = nil
        let hook = Task {
            try await endpoint.invoke(
                "activity.hook.claude",
                payload: Data(
                    #"{"hook_event_name":"PermissionRequest","session_id":"synthetic-parent","tool_use_id":"synthetic-request","cwd":"/tmp/synthetic-provider","tool_name":"Bash","tool_input":{"command":"printf synthetic"}}"#
                        .utf8), timeout: 120)
        }
        defer { hook.cancel() }
        let pending = try await permission(endpoint, tile)
        guard let row = pending.rows.first(where: { $0.field == "approvals" }),
            let allow = row.actions.first(where: { $0.title == "Allow once" }),
            UUID(uuidString: allow.id) != nil
        else { throw HostWorkerError.invalidResponse }
        var wrongProvider = tile
        wrongProvider.sourceIDs = ["codex"]
        let rejected = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: wrongProvider), actionID: allow.id)
        var refusal = false
        do {
            _ = try await endpoint.invoke(
                "surface.perform", payload: rejected.encoded(providerID: "herdr"))
        } catch { refusal = true }
        guard refusal else { throw HostWorkerError.invalidResponse }
        let action = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: allow.id)
        _ = try await endpoint.invoke(
            "surface.perform", payload: action.encoded(providerID: "herdr"))
        let output = try JSONSerialization.jsonObject(with: await hook.value) as? [String: Any]
        guard let specific = output?["hookSpecificOutput"] as? [String: Any],
            let decision = specific["decision"] as? [String: Any],
            decision["behavior"] as? String == "allow",
            decision["updatedPermissions"] == nil,
            try await snapshot(endpoint, tile).metrics.first(where: { $0.id == "permissions" })?
                .value == "0"
        else { throw HostWorkerError.invalidResponse }
        let cancelled = Task {
            try await endpoint.invoke(
                "activity.hook.claude",
                payload: Data(
                    #"{"hook_event_name":"PermissionRequest","session_id":"synthetic-parent","tool_use_id":"synthetic-cancel","cwd":"/tmp/synthetic-provider","tool_name":"Read","tool_input":{"file_path":"/tmp/synthetic.txt"}}"#
                        .utf8), timeout: 120)
        }
        _ = try await permission(endpoint, tile)
        cancelled.cancel()
        _ = try? await cancelled.value
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if try await snapshot(endpoint, tile).metrics.first(where: { $0.id == "permissions" })?
                .value == "0"
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw HostWorkerError.invalidResponse
    }

    @MainActor private static func permission(
        _ endpoint: ExtensionPeerEndpoint, _ tile: SurfaceTile
    ) async throws -> SurfaceSnapshot {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            let value = try await snapshot(endpoint, tile)
            if value.metrics.first(where: { $0.id == "permissions" })?.value == "1" { return value }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw HostWorkerError.invalidResponse
    }

    @MainActor private static func snapshot(_ endpoint: ExtensionPeerEndpoint, _ tile: SurfaceTile)
        async throws -> SurfaceSnapshot
    {
        try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot",
                payload:
                    SurfaceSnapshotRequest(target: .home, tile: tile).encoded(providerID: "herdr")),
            providerID: "herdr")
    }

    @MainActor private static func object(
        _ endpoint: ExtensionPeerEndpoint, _ command: String, _ payload: Data
    ) async throws -> [String: Any] {
        guard
            let value = try JSONSerialization.jsonObject(
                with: await endpoint.invoke(command, payload: payload)) as? [String: Any]
        else { throw HostWorkerError.invalidResponse }
        return value
    }
}
