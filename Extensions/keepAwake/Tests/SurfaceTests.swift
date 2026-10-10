import EdithExtensionSupport
import Foundation
import Testing
@testable import KeepAwakeExtension

struct KeepAwakeExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let off = KeepAwakeSurface.snapshot(preventingSleep: false, requested: false)
        let failed = KeepAwakeSurface.snapshot(preventingSleep: false, requested: true)
        #expect(off.rows.first?.value == "Off")
        #expect(off.actions.first?.id == "enable")
        #expect(failed.actions.first?.id == "disable")
        #expect(failed.message != nil)
        _ = try SurfaceSnapshot.decode(failed.encoded(), providerID: "keepAwake")
    }
    @Test @MainActor func currentActionsToggleTheOwnedAssertionAndRejectStaleTokens() async throws {
        let name = "test.surface.keepAwake." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: KeepAwakeKeys.enabled)
        var released = 0
        let store = KeepAwakeStore(
            defaults: defaults, notificationCenter: NotificationCenter(),
            workspaceNotifications: NotificationCenter(), reconciliationInterval: nil,
            createAssertion: { 7 }, assertionIsActive: { _ in true },
            releaseAssertion: { _ in released += 1 })
        defer { store.shutdown() }
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.actions))
        let enable = SurfaceActionRequest(snapshot: request, actionID: "enable")
        let enabled = try await KeepAwakeSurface.execute(
            "surface.perform", payload: enable.encoded(providerID: "keepAwake"), store: store,
            defaults: defaults)
        #expect(store.preventingSleep && defaults.bool(forKey: "preventSleep"))
        #expect(
            try SurfaceSnapshot.decode(enabled, providerID: "keepAwake").actions.first?.id
                == "disable")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await KeepAwakeSurface.execute(
                "surface.perform", payload: enable.encoded(providerID: "keepAwake"), store: store,
                defaults: defaults)
        }
        let disable = SurfaceActionRequest(snapshot: request, actionID: "disable")
        _ = try await KeepAwakeSurface.execute(
            "surface.perform", payload: disable.encoded(providerID: "keepAwake"), store: store,
            defaults: defaults)
        #expect(!store.preventingSleep && !defaults.bool(forKey: "preventSleep"))
        #expect(released == 1)
    }

}
