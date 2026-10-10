import EdithExtensionSupport
import EdithHostCore
import Foundation

enum SystemFixture {
    @MainActor static func verify(_ endpoint: ExtensionPeerEndpoint) async throws {
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil else {
            throw HostWorkerError.rejected
        }
        let initial = try await object(endpoint, command: "system.cleaning.status")
        guard initial["phase"] as? String == "idle", initial["armingCountdown"] as? Int == 0,
            initial["failsafeRemaining"] as? Int == 0
        else { throw HostWorkerError.invalidResponse }
        var tile = SurfaceTile(.actions)
        tile.itemLimit = 1
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let before = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot", payload: request.encoded(providerID: "system"), timeout: 5),
            providerID: "system")
        guard before.actions.contains(where: { $0.id == "cleanKeys" }), before.rows.isEmpty else {
            throw HostWorkerError.invalidResponse
        }
        do {
            _ = try await endpoint.invoke(
                "system.cleanKeys", payload: Data("{\"path\":\"/tmp/invalid\"}".utf8), timeout: 5)
            throw HostWorkerError.invalidResponse
        } catch ExtensionPeerError.rejected {}
        let started = try await object(endpoint, command: "system.cleanKeys")
        guard started["result"] as? String == "arming",
            let status = started["status"] as? [String: Any],
            status["phase"] as? String == "arming", status["armingCountdown"] as? Int == 3
        else {
            throw HostWorkerError.invalidResponse
        }
        let stale = SurfaceActionRequest(snapshot: request, actionID: "cleanKeys")
        do {
            _ = try await endpoint.invoke(
                "surface.perform", payload: stale.encoded(providerID: "system"), timeout: 5)
            throw HostWorkerError.invalidResponse
        } catch ExtensionPeerError.rejected {}
        let stopped = try await object(endpoint, command: "system.stopCleaning")
        guard stopped["phase"] as? String == "idle", stopped["armingCountdown"] as? Int == 0,
            stopped["failsafeRemaining"] as? Int == 0
        else { throw HostWorkerError.invalidResponse }
        let active = try await object(endpoint, command: "system.cleanKeys")
        guard active["result"] as? String == "arming" else { throw HostWorkerError.invalidResponse }
    }

    private static func object(_ endpoint: ExtensionPeerEndpoint, command: String) async throws
        -> [String: Any]
    {
        let data = try await endpoint.invoke(command, payload: Data("{}".utf8), timeout: 5)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostWorkerError.invalidResponse
        }
        return value
    }
}
