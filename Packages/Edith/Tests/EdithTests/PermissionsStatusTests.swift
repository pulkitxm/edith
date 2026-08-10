import Testing

@testable import EdithKit

@Suite struct PermissionsStatusTests {
    func usages(
        enabled: [String] = [], missing: [ExtensionPermission] = []
    ) -> [PermissionUsage] {
        let enabledKeys = Set(
            ExtensionRegistry.entries.filter { enabled.contains($0.id) }.map(\.defaultsKey))
        let granted = ExtensionPermission.allCases.reduce(into: [ExtensionPermission: Bool]()) {
            $0[$1] = !missing.contains($1)
        }
        return PermissionCatalog.usages(enabledKeys: enabledKeys, granted: granted)
    }

    func needsAttention(enabled: [String] = [], missing: [ExtensionPermission] = []) -> Bool {
        PermissionCatalog.needsAttention(usages(enabled: enabled, missing: missing))
    }

    @Test func allGrantedNeedsNothing() {
        #expect(!needsAttention(enabled: ["usage", "calendar", "system", "focusDim"]))
    }

    @Test func missingPermissionOnlyWarnsWhenExtensionIsOn() {
        #expect(!needsAttention(missing: [.calendar]))
        #expect(needsAttention(enabled: ["calendar"], missing: [.calendar]))
    }

    @Test func optionalPermissionsNeverBlock() {
        #expect(!needsAttention(enabled: ["system"], missing: [.accessibility, .inputMonitoring]))
        #expect(!needsAttention(enabled: ["notchShelf"], missing: [.camera]))
    }

    @Test func screenRecordingBlocksEveryExtensionThatRequiresIt() {
        for id in ["focusDim", "presenter", "colorPicker"] {
            #expect(needsAttention(enabled: [id], missing: [.screenRecording]))
        }
    }

    @Test func mineFilterKeepsOnlyPermissionsEnabledExtensionsUse() {
        let filtered = PermissionCatalog.filter(usages(enabled: ["calendar"]), by: .mine)
        #expect(filtered.map(\.permission) == [.calendar])
    }

    @Test func attentionFilterKeepsOnlyBlockedPermissions() {
        let all = usages(enabled: ["calendar", "notchShelf"], missing: [.calendar, .camera])
        #expect(PermissionCatalog.filter(all, by: .attention).map(\.permission) == [.calendar])
        #expect(PermissionCatalog.filter(all, by: .all).count == ExtensionPermission.allCases.count)
    }

    @Test func grantableSkipsFirstUseOnlyPermissions() {
        let all = usages(enabled: ["notchShelf"], missing: [.camera, .bluetooth, .automation])
        #expect(PermissionCatalog.grantable(all).map(\.permission) == [.camera])
    }

    @Test func firstUsePermissionsAreFlagged() {
        let all = usages()
        let firstUse = all.filter(\.grantsOnFirstUse).map(\.permission)
        #expect(Set(firstUse) == [.bluetooth, .automation])
    }
}
