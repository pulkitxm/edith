import EdithExtensionSupport
import Foundation
import Testing
@testable import PluginsExtension

@Suite struct PluginsFixtureSurfacePolicyTests {
    @MainActor @Test func malformedSurfaceRequestsNeverReachTheExecutor() async throws {
        let policy = try PluginsFixturePolicy(
            validateSurface: PluginsSurface.validate, requireCurrent: {})
        var calls = 0
        for command in ["surface.snapshot", "surface.perform"] {
            for body in ["{}", "null", "[]", "{", String(repeating: " ", count: 131_073)] {
                await #expect(throws: (any Error).self) {
                    _ = try await policy.perform(
                        command, payload: Data(body.utf8), skillIDs: [], agentIDs: []
                    ) {
                        calls += 1
                        return Data()
                    }
                }
                #expect(calls == 0)
            }
        }
        let snapshot = SurfaceSnapshotRequest(
            target: .home, tile: SurfaceTile(.ability("plugins")))
        let deniedAction = try SurfaceActionRequest(
            snapshot: snapshot, actionID: "install"
        ).encoded(providerID: "plugins")
        await #expect(throws: (any Error).self) {
            _ = try await policy.perform(
                "surface.perform", payload: deniedAction, skillIDs: [], agentIDs: []
            ) {
                calls += 1
                return Data()
            }
        }
        #expect(calls == 0)
        let snapshotBytes = try snapshot.encoded(providerID: "plugins")
        var snapshotFields = try #require(
            JSONSerialization.jsonObject(with: snapshotBytes) as? [String: Any])
        snapshotFields["unexpected"] = true
        var tileFields = try #require(snapshotFields["tile"] as? [String: Any])
        tileFields["unexpected"] = true
        var nestedFields = snapshotFields
        nestedFields.removeValue(forKey: "unexpected")
        nestedFields["tile"] = tileFields
        for fields in [snapshotFields, nestedFields] {
            let payload = try JSONSerialization.data(withJSONObject: fields)
            await #expect(throws: (any Error).self) {
                _ = try await policy.perform(
                    "surface.snapshot", payload: payload, skillIDs: [], agentIDs: []
                ) {
                    calls += 1
                    return Data()
                }
            }
            #expect(calls == 0)
        }
    }

}
