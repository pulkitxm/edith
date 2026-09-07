import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@MainActor @Suite struct PermissionsModelLifecycleTests {
    @Test func refreshCoalescesAndPublishesOnlyTheLatestCompleteSnapshot() async throws {
        let fixture = PermissionLifecycleFixture()
        let entered = PermissionLifecycleGate()
        let release = PermissionLifecycleGate()
        let calls = PermissionLifecycleCounter()
        let model = fixture.model(read: {
            let index = await calls.next()
            if index == 1 {
                await entered.signal()
                await release.wait()
            }
            return Self.snapshot(index != 1)
        })
        model.refresh(force: true)
        await entered.wait()
        for _ in 0..<100 { model.refresh(force: true) }
        #expect(await calls.count == 1)
        await release.signal()
        await model.waitForRefresh()
        #expect(await calls.count == 2)
        #expect(fixture.publications == 1)
        #expect(fixture.recorded == [[true, true, true, true, true, true]])
        #expect(model.notifications && model.accessibility && model.inputMonitoring)
        #expect(model.fullDisk && model.screenRecording && model.camera)
        model.shutdown()
        await model.waitForShutdown()
    }

    @Test func stopAndRestartIgnoreTheRetiredRead() async {
        let fixture = PermissionLifecycleFixture()
        let entered = PermissionLifecycleGate()
        let release = PermissionLifecycleGate()
        let calls = PermissionLifecycleCounter()
        let model = fixture.model(read: {
            let index = await calls.next()
            if index == 1 {
                await entered.signal()
                await release.wait()
            }
            return Self.snapshot(index == 1)
        })
        model.refresh(force: true)
        await entered.wait()
        model.shutdown()
        model.startIPCBridge()
        model.refresh(force: true)
        await release.signal()
        await model.waitForRefresh()
        #expect(fixture.recorded == [[false, false, false, false, false, false]])
        #expect(!model.camera)
        model.shutdown()
        await model.waitForShutdown()
    }

    @Test func failedReadPreservesTheLastGrantedStatus() async {
        let fixture = PermissionLifecycleFixture()
        let calls = PermissionLifecycleCounter()
        let model = fixture.model(read: {
            if await calls.next() == 2 { throw AgentError(.failed, "Fixture read failure") }
            return Self.snapshot(true)
        })
        model.refresh(force: true)
        await model.waitForRefresh()
        model.refresh(force: true)
        await model.waitForRefresh()
        #expect(model.notifications && model.camera)
        #expect(fixture.publications == 1)
        #expect(model.refreshError == "Fixture read failure")
        model.refresh(force: true)
        await model.waitForRefresh()
        #expect(model.refreshError == nil)
        model.shutdown()
        await model.waitForShutdown()
    }

    @Test func grantRequestsRemainBoundedAndOldCallbacksDoNotRefreshAfterRestart() async throws {
        let fixture = PermissionLifecycleFixture()
        let calls = PermissionLifecycleCounter()
        let model = fixture.model(read: {
            _ = await calls.next()
            return Self.snapshot(true)
        })
        for _ in 0..<100 { model.request(.calendar) }
        #expect(fixture.grants.count == 1)
        #expect(model.pendingGrantCount == 1)
        model.shutdown()
        model.startIPCBridge()
        model.request(.calendar)
        #expect(fixture.grants.count == 1)
        fixture.grants[0]()
        try await wait { model.pendingGrantCount == 0 }
        #expect(await calls.count == 0)
        #expect(fixture.publications == 0)
        model.request(.calendar)
        #expect(fixture.grants.count == 2)
        fixture.grants[1]()
        try await wait { fixture.publications == 1 }
        model.shutdown()
        await model.waitForShutdown()
        #expect(await calls.count == 1)
    }

    @Test func shutdownCancelsDelayedFollowUpsWithoutDiscardingKnownStatus() async throws {
        let fixture = PermissionLifecycleFixture()
        let calls = PermissionLifecycleCounter()
        let delayStarted = PermissionLifecycleGate()
        let delayCancelled = PermissionLifecycleCounter()
        let model = fixture.model(
            read: {
                _ = await calls.next()
                return Self.snapshot(true)
            },
            delay: { _ in
                await delayStarted.signal()
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    _ = await delayCancelled.next()
                    throw error
                }
            })
        model.request(.notifications)
        fixture.grants[0]()
        await delayStarted.wait()
        await model.waitForRefresh()
        model.shutdown()
        await model.waitForShutdown()
        model.refresh(force: true)
        #expect(await calls.count == 1)
        #expect(await delayCancelled.count == 1)
        #expect(model.notifications)
    }

    nonisolated private static func snapshot(_ granted: Bool) -> PermissionsModel.Snapshot {
        PermissionsModel.Snapshot(
            notifications: granted, accessibility: granted, inputMonitoring: granted,
            fullDisk: granted, screenRecording: granted, camera: granted)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw AgentError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private final class PermissionLifecycleFixture {
    private let suite = "edith-permissions-\(UUID().uuidString)"
    let defaults: UserDefaults
    var publications = 0
    var recorded: [[Bool]] = []
    var grants: [@Sendable () -> Void] = []

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    func model(
        read: @escaping @Sendable () async throws -> PermissionsModel.Snapshot,
        delay: @escaping @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(30))
        }
    ) -> PermissionsModel {
        PermissionsModel(
            readStatus: read,
            requestPlatform: { [self] _, complete in
                grants.append(complete); return false
            },
            defaults: defaults,
            publishChange: { [self] in
                publications += 1
                recorded.append(
                    [
                        AppStorageKeys.Permissions.notificationsGranted,
                        AppStorageKeys.Permissions.accessibilityGranted,
                        AppStorageKeys.Permissions.inputMonitoringGranted,
                        AppStorageKeys.Permissions.fullDiskGranted,
                        AppStorageKeys.Permissions.screenRecordingGranted,
                        AppStorageKeys.Permissions.cameraGranted,
                    ].map { defaults.bool(forKey: $0) })
            }, openSettings: { _ in false }, recordPrompt: {}, delay: delay)
    }
}

private actor PermissionLifecycleGate {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor PermissionLifecycleCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
