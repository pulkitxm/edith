import EdithExtensionSupport
import Foundation
import Testing

@testable import KeepAwakeExtension

@Suite @MainActor struct KeepAwakeFixtureStoreTests {
    @Test func syntheticAssertionTracksOriginalControlsAndShutdown() async throws {
        let suite = "com.pulkit.edith.tests.keep-awake-store." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeKeys.enabled)
        let store = KeepAwakeStore.fixture(defaults: defaults)
        defer { store.shutdown() }
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.actions))
        let initial = try await KeepAwakeSurface.execute(
            "surface.snapshot", payload: request.encoded(providerID: "keepAwake"), store: store,
            defaults: defaults)
        #expect(
            try SurfaceSnapshot.decode(initial, providerID: "keepAwake").rows.first?.value == "Off")
        let enable = SurfaceActionRequest(snapshot: request, actionID: "enable")
        let enabled = try await KeepAwakeSurface.execute(
            "surface.perform", payload: enable.encoded(providerID: "keepAwake"), store: store,
            defaults: defaults)
        #expect(store.preventingSleep)
        #expect(
            try SurfaceSnapshot.decode(enabled, providerID: "keepAwake").rows.first?.value
                == "Awake")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await KeepAwakeSurface.execute(
                "surface.perform", payload: enable.encoded(providerID: "keepAwake"), store: store,
                defaults: defaults)
        }
        let disable = SurfaceActionRequest(snapshot: request, actionID: "disable")
        _ = try await KeepAwakeSurface.execute(
            "surface.perform", payload: disable.encoded(providerID: "keepAwake"), store: store,
            defaults: defaults)
        #expect(!store.preventingSleep)
        defaults.set(true, forKey: AppStorageKeys.General.preventSleep)
        store.syncPreventSleep()
        #expect(store.preventingSleep)
        store.shutdown()
        store.syncPreventSleep()
        #expect(!store.preventingSleep)
    }

    @Test func fixtureIgnoresGlobalPreferenceAndWorkspaceBroadcasts() async throws {
        let suite = "com.pulkit.edith.tests.keep-awake-store." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeKeys.enabled)
        let store = KeepAwakeStore.fixture(defaults: defaults)
        defer { store.shutdown() }
        defaults.set(true, forKey: AppStorageKeys.General.preventSleep)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        for _ in 0..<50 { await Task.yield() }
        #expect(!store.preventingSleep)
        store.syncPreventSleep()
        #expect(store.preventingSleep)
        defaults.set(false, forKey: KeepAwakeKeys.enabled)
        store.syncPreventSleep()
        #expect(!store.preventingSleep)
        #expect(defaults.bool(forKey: AppStorageKeys.General.preventSleep))
    }
}
