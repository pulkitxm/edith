import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct RunningAppsModelTests {
    static let finder = RunningAppSnapshot(
        pid: 1, name: "Finder", bundleID: "com.apple.finder", active: false)
    static let safari = RunningAppSnapshot(
        pid: 2, name: "Safari", bundleID: "com.apple.Safari", active: true)
    static let music = RunningAppSnapshot(
        pid: 3, name: "Music", bundleID: "com.apple.Music", active: false)

    @Test func protectedAppPlanFailureIsObservable() {
        let model = RunningAppsModel(
            operations: RunningAppOperationCenter(snapshot: { [Self.finder] }))

        model.quit(Self.row(Self.finder))

        #expect(model.actionStatus == .planRejected(.protected("Finder")))
        #expect(model.actionStatus?.message.contains("protects essential apps") == true)
    }

    @Test func rejectedQuitIsObservableAndActionable() {
        let model = RunningAppsModel(
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
        let model = RunningAppsModel(
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

    @Test func filtersSearchNameBundleIdentifierAndPIDAndSurviveRefresh() async {
        let model = RunningAppsModel(
            operations: RunningAppOperationCenter(snapshot: { [Self.safari, Self.music] }))
        await model.refresh()
        model.query = " SAFARI "
        #expect(model.visibleApps.map(\.pid) == [2])
        model.query = "com.apple.Music"
        #expect(model.visibleApps.map(\.pid) == [3])
        model.query = "2"
        await model.refresh()
        #expect(model.query == "2")
        #expect(model.visibleApps.map(\.pid) == [2])
        model.query = "absent app"
        #expect(model.visibleApps.isEmpty)
        model.query = ""
        #expect(model.visibleApps.count == 2)
    }

    @Test func partialQuitAllOutcomeReportsAcceptedAndRemainingCounts() {
        let model = RunningAppsModel(
            operations: RunningAppOperationCenter(
                snapshot: { [Self.finder, Self.safari, Self.music] },
                perform: { _, _ in 1 }))

        model.quitAll()

        #expect(model.actionStatus == .partial(changed: 1, requested: 2, force: false))
        #expect(model.actionStatus?.message.contains("1 of 2 apps") == true)
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
