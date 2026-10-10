import Foundation
import Testing

@testable import SystemExtension
import EdithExtensionSupport
import EdithExtensionUI

@Suite @MainActor final class RunningAppsModelTests {
    private let suite = "fixture.system." + UUID().uuidString
    private let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }

    private func makeModel(operations: RunningAppOperationCenter = RunningAppOperationCenter())
        -> RunningAppsModel
    {
        RunningAppsModel(operations: operations, defaults: defaults)
    }

    static let finder = RunningAppSnapshot(
        pid: 1, name: "Finder", bundleID: "com.apple.finder", active: false)
    static let safari = RunningAppSnapshot(
        pid: 2, name: "Safari", bundleID: "com.apple.Safari", active: true)
    static let music = RunningAppSnapshot(
        pid: 3, name: "Music", bundleID: "com.apple.Music", active: false)

    @Test func protectedAppPlanFailureIsObservable() {
        let model = makeModel(
            operations: RunningAppOperationCenter(snapshot: { [Self.finder] }))

        model.quit(Self.row(Self.finder))

        #expect(model.actionStatus == .planRejected(.protected("Finder")))
        #expect(model.actionStatus?.message.contains("protects essential apps") == true)
    }

    @Test func rejectedQuitIsObservableAndActionable() {
        let model = makeModel(
            operations: RunningAppOperationCenter(
                snapshot: { [Self.safari] }, perform: { _, _ in 0 }))

        model.quit(Self.row(Self.safari))

        #expect(
            model.actionStatus
                == .rejected(name: "Safari", requested: 1, force: false))
        #expect(model.actionStatus?.message.contains("Resolve any open dialogs") == true)
    }

    @Test func secondRefreshKeepsRowIdentityAndReadsSnapshotsOffTheMainActor() async {
        let samples = AppSamples(snapshots: [Self.safari, Self.music])
        let model = makeModel(
            operations: RunningAppOperationCenter(
                snapshot: {
                    #expect(!Thread.isMainThread)
                    return samples.snapshots
                },
                resource: { pid in
                    RunningAppResourceSample(
                        cpuNanoseconds: samples.nanos[pid] ?? 0, memoryMB: pid == 2 ? 80 : 20)
                }))

        await model.refresh()
        let safari = model.apps.first { $0.pid == Self.safari.pid }
        let music = model.apps.first { $0.pid == Self.music.pid }
        samples.nanos[Self.safari.pid] = 3_000_000_000
        await model.refresh()

        #expect(model.apps.first { $0.pid == Self.safari.pid } === safari)
        #expect(model.apps.first { $0.pid == Self.music.pid } === music)
        #expect(model.apps.count == 2)
    }

    @Test func partialQuitAllOutcomeReportsAcceptedAndRemainingCounts() {
        let model = makeModel(
            operations: RunningAppOperationCenter(
                snapshot: { [Self.finder, Self.safari, Self.music] },
                perform: { _, _ in 1 }))

        model.quitAll()

        #expect(model.actionStatus == .partial(changed: 1, requested: 2, force: false))
        #expect(model.actionStatus?.message.contains("1 of 2 apps") == true)
    }

    @Test func shutdownRejectsLateSnapshotsAndFurtherQuitRequests() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let samples = AppSamples(snapshots: [Self.safari])
        let model = makeModel(
            operations: RunningAppOperationCenter(
                snapshot: {
                    entered.signal()
                    release.wait()
                    return samples.snapshots
                },
                perform: { _, _ in
                    Issue.record("A stopped model must not quit applications.")
                    return 1
                }))
        let refresh = Task { await model.refresh() }
        let arrived = await Task.detached { Self.waitForSnapshot(entered) }.value
        #expect(arrived == .success)
        model.shutdown()
        release.signal()
        await refresh.value
        await model.refresh()
        model.quit(Self.row(Self.safari))
        model.quitAll()
        #expect(model.apps.isEmpty)
        #expect(model.totalMemoryMB == 0)
        #expect(!model.refreshing)
        #expect(model.actionStatus == nil)
    }

    @Test func everyEdithIdentityRemainsProtectedWhenQuittingAll() async throws {
        let identities = [
            "com.pulkit.edith", "com.pulkit.edith.dev.fixture",
            "com.pulkit.edith.tests.fixture", "com.pulkit.edith.helper.v2",
        ]
        let protected = identities.enumerated().map { index, identity in
            RunningAppSnapshot(
                pid: Int32(index + 100), name: "Fixture", bundleID: identity,
                active: false)
        }
        let operations = RunningAppOperationCenter(snapshot: { protected + [Self.safari] })
        let model = makeModel(operations: operations)
        await model.refresh()
        #expect(model.quitAllTargetCount == 1)
        #expect(model.apps.filter { !model.canQuit($0) }.count == protected.count)
        #expect(try operations.plan(.all).targets == [Self.safari])
        model.shutdown()
    }

    nonisolated private static func waitForSnapshot(_ gate: DispatchSemaphore)
        -> DispatchTimeoutResult
    {
        gate.wait(timeout: .now() + 5)
    }

    private final class AppSamples: @unchecked Sendable {
        var snapshots: [RunningAppSnapshot]
        var nanos: [Int32: UInt64] = [:]

        init(snapshots: [RunningAppSnapshot]) {
            self.snapshots = snapshots
        }
    }

    private static func row(_ app: RunningAppSnapshot) -> RunningAppRow {
        RunningAppRow(
            pid: app.pid, name: app.name, bundleID: app.bundleID, icon: nil,
            cpuPercent: app.cpuPercent, memoryMB: app.memoryMB)
    }
}
