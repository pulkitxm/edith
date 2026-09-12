import AppKit
import EdithKit
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import EdithHelper

@MainActor
private final class KeepAwakeTestWorld {
    let suite = "test.keep-awake.\(UUID().uuidString)"
    let notifications = NotificationCenter()
    let workspaceNotifications = NotificationCenter()
    let defaults: UserDefaults
    var store: KeepAwakeStore?
    var creations = 0
    var failuresRemaining = 0
    var activeAssertions: Set<IOPMAssertionID> = []
    var releases: [IOPMAssertionID] = []

    init(enabled: Bool = true, requested: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(enabled, forKey: AppStorageKeys.General.keepAwakeEnabled)
        defaults.set(requested, forKey: AppStorageKeys.General.preventSleep)
    }

    func start(interval: TimeInterval = 30) -> KeepAwakeStore {
        let store = KeepAwakeStore(
            defaults: defaults, notificationCenter: notifications,
            workspaceNotifications: workspaceNotifications,
            reconciliationInterval: interval,
            createAssertion: { [self] in
                creations += 1
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    return nil
                }
                let assertion = IOPMAssertionID(creations)
                activeAssertions.insert(assertion)
                return assertion
            },
            assertionIsActive: { [self] in activeAssertions.contains($0) },
            releaseAssertion: { [self] in
                releases.append($0)
                activeAssertions.remove($0)
            })
        self.store = store
        return store
    }

    func finish() {
        store?.shutdown()
        store = nil
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite @MainActor struct KeepAwakeStoreTests {
    @Test func helperRestartRestoresRequestedProtection() {
        let world = KeepAwakeTestWorld()
        defer { world.finish() }
        let original = world.start()
        #expect(original.preventingSleep)
        original.shutdown()
        #expect(world.defaults.bool(forKey: AppStorageKeys.General.preventSleep))
        #expect(world.activeAssertions.isEmpty)

        let restarted = world.start()
        #expect(restarted.preventingSleep)
        #expect(world.activeAssertions.count == 1)
        #expect(world.creations == 2)
    }

    @Test func disabledExtensionDoesNotAcquireAnAssertion() {
        let world = KeepAwakeTestWorld(enabled: false)
        defer { world.finish() }
        let store = world.start()
        #expect(!store.preventingSleep)
        #expect(world.creations == 0)
    }

    @Test func localPreferenceChangeAppliesWithoutMainAppBroadcast() async {
        let world = KeepAwakeTestWorld(requested: false)
        defer { world.finish() }
        let store = world.start()
        world.defaults.set(true, forKey: AppStorageKeys.General.preventSleep)
        world.notifications.post(name: UserDefaults.didChangeNotification, object: world.defaults)
        for _ in 0..<50 { await Task.yield() }
        #expect(store.preventingSleep)
        #expect(world.activeAssertions.count == 1)

        world.defaults.set(false, forKey: AppStorageKeys.General.preventSleep)
        world.notifications.post(name: UserDefaults.didChangeNotification, object: world.defaults)
        for _ in 0..<50 { await Task.yield() }
        #expect(!store.preventingSleep)
        #expect(world.activeAssertions.isEmpty)
    }

    @Test func unchangedProtectionDoesNotDuplicateAssertions() {
        let world = KeepAwakeTestWorld()
        defer { world.finish() }
        let store = world.start()
        store.syncPreventSleep()
        store.syncPreventSleep()
        #expect(world.creations == 1)
        #expect(world.releases.isEmpty)
    }

    @Test func wakeReplacesInvalidatedAssertion() async {
        let world = KeepAwakeTestWorld()
        defer { world.finish() }
        let store = world.start()
        world.activeAssertions.removeAll()
        world.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(store.preventingSleep)
        #expect(world.creations == 2)
        #expect(world.activeAssertions == [2])
    }

    @Test func failedAcquisitionRetriesWithoutChangingThePreference() async throws {
        let world = KeepAwakeTestWorld()
        defer { world.finish() }
        world.failuresRemaining = 1
        let store = world.start(interval: 0.01)
        #expect(!store.preventingSleep)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.preventingSleep)
        #expect(world.creations == 2)
        #expect(world.defaults.bool(forKey: AppStorageKeys.General.preventSleep))
    }

    @Test func disablingExtensionReleasesRequestedProtection() {
        let world = KeepAwakeTestWorld()
        defer { world.finish() }
        let store = world.start()
        world.defaults.set(false, forKey: AppStorageKeys.General.keepAwakeEnabled)
        store.syncPreventSleep()
        #expect(!store.preventingSleep)
        #expect(world.activeAssertions.isEmpty)
    }

    @Test func shutdownCannotReacquireFromQueuedReconciliation() async throws {
        let world = KeepAwakeTestWorld()
        defer { world.finish() }
        let store = world.start(interval: 0.01)
        world.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        world.notifications.post(name: UserDefaults.didChangeNotification, object: world.defaults)
        store.shutdown()
        store.shutdown()
        store.syncPreventSleep()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.preventingSleep)
        #expect(world.creations == 1)
        #expect(world.releases == [1])
        #expect(world.activeAssertions.isEmpty)
    }
}
