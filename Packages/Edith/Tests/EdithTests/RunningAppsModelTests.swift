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

    @Test func partialQuitAllOutcomeReportsAcceptedAndRemainingCounts() {
        let model = RunningAppsModel(
            operations: RunningAppOperationCenter(
                snapshot: { [Self.finder, Self.safari, Self.music] },
                perform: { _, _ in 1 }))

        model.quitAll()

        #expect(model.actionStatus == .partial(changed: 1, requested: 2, force: false))
        #expect(model.actionStatus?.message.contains("1 of 2 apps") == true)
    }

    private static func row(_ app: RunningAppSnapshot) -> RunningAppRow {
        RunningAppRow(
            pid: app.pid, name: app.name, bundleID: app.bundleID, icon: nil,
            cpuPercent: app.cpuPercent, memoryMB: app.memoryMB)
    }
}
