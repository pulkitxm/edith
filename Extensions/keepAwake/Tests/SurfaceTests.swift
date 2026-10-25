import EdithExtensionSupport
import Foundation
import Testing
@testable import KeepAwakeExtension

struct KeepAwakeExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let off = KeepAwakeSurface.snapshot(requested: false)
        let on = KeepAwakeSurface.snapshot(requested: true)
        #expect(off.metrics.first?.title == "Current state")
        #expect(off.metrics.first?.value == "Off")
        #expect(off.rows.isEmpty && off.message == nil)
        #expect(off.actions.first?.id == "enable")
        #expect(off.actions.first?.title == "Turn on")
        #expect(off.actions.first?.icon == "moon.zzz")
        #expect(on.metrics.first?.value == "On")
        #expect(on.actions.first?.id == "disable")
        #expect(on.actions.first?.title == "Turn off")
        _ = try SurfaceSnapshot.decode(on.encoded(), providerID: "keepAwake")
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
