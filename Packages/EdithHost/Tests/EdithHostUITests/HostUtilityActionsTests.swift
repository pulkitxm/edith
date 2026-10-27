import EdithExtensionSupport
import Testing

@testable import EdithHost

@MainActor
@Suite struct HostUtilityActionsTests {
    private func snapshot(_ id: String, offering action: String) -> SurfaceSnapshot {
        SurfaceSnapshot(providerID: id, actions: [.init(action, action, "moon.zzz")])
    }

    @Test func keepAwakeStateFollowsTheOwnersSnapshot() {
        let actions = HostUtilityActions()
        #expect(!actions.isOn(.keepAwake))
        actions.snapshots["keepAwake"] = snapshot("keepAwake", offering: "disable")
        #expect(actions.isOn(.keepAwake))
        actions.snapshots["keepAwake"] = snapshot("keepAwake", offering: "enable")
        #expect(!actions.isOn(.keepAwake))
    }

    @Test func pendingKeepAwakeOverridesTheSnapshotUntilTheActionEnds() {
        let actions = HostUtilityActions()
        actions.snapshots["keepAwake"] = snapshot("keepAwake", offering: "enable")
        actions.pendingKeepAwake = true
        #expect(actions.isOn(.keepAwake))
        actions.pendingKeepAwake = nil
        #expect(!actions.isOn(.keepAwake))
    }

    @Test func otherUtilitiesKeepReadingTheirSnapshots() {
        let actions = HostUtilityActions()
        actions.snapshots["lidAwake"] = snapshot("lidAwake", offering: "off")
        #expect(actions.isOn(.lidAwake))
        actions.snapshots["lidAwake"] = snapshot("lidAwake", offering: "on")
        #expect(!actions.isOn(.lidAwake))
    }
}
