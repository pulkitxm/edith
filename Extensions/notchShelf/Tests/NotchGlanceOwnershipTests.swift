import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@Suite @MainActor struct NotchGlanceOwnershipTests {
    @Test func hiddenOrIntrinsicGlancesDoNotRequestAnyProvider() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.controller.layouts.update(.notch) {
            $0.notchLeadingGlance = .none
            $0.notchTrailingGlance = .clock
            $0.notchExpandPermissions = false
            $0.notchPrioritizePermissions = false
        }
        #expect(fixture.controller.glanceProviderIDs.isEmpty)
        #expect(fixture.controller.leadingGlance == nil)
        #expect(fixture.controller.trailingGlance?.source == .clock)
        fixture.controller.layouts.update(.notch) { $0.notchLeadingGlance = .files }
        #expect(fixture.controller.glanceProviderIDs.isEmpty)
        #expect(fixture.controller.leadingGlance == nil)
        fixture.controller.layouts.update(.notch) { $0.notchLeadingGlance = .nextMeeting }
        #expect(fixture.controller.glanceProviderIDs == ["calendar"])
    }

    @Test func liveSnapshotIsClearedImmediatelyOnDisableOrPrivacyChange() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.controller.layouts.update(.notch) { $0.notchLeadingGlance = .nextMeeting }
        let snapshot = SurfaceSnapshot(
            providerID: "calendar",
            rows: [.init("mock-meeting", title: "Synthetic planning session")])
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(fixture.controller.leadingGlance?.value == "Synthetic planni")
        let presenter = ExtensionSharedState(
            root: fixture.root, namespace: fixture.id, owner: "presenter")
        try presenter.publish(["active": "1", "blurCalendar": "1"])
        fixture.controller.synchronize()
        #expect(fixture.controller.surfaceSnapshots.isEmpty)
        #expect(fixture.controller.leadingGlance == nil)
        try presenter.clear("presenter")
        fixture.controller.synchronize()
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(fixture.controller.leadingGlance != nil)
        try fixture.state.publish([
            "surface.activeIDs": "[\"notchShelf\"]",
            "surface.activeVersions": "{\"notchShelf\":\"1\"}",
        ])
        fixture.controller.synchronize()
        #expect(fixture.controller.surfaceSnapshots.isEmpty)
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(fixture.controller.leadingGlance == nil)
    }

    @Test func customizationRequestPreservesProviderStatusAndUsesUniqueTokens() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let state = ExtensionSharedState(
            root: fixture.root, namespace: fixture.id, owner: "notchShelf")
        try state.publish(["files": "5"])
        fixture.controller.openCustomization(tileID: "calendar")
        let first = state.values(for: "notchShelf")
        #expect(first["surface.openEditor"] == "notch")
        #expect(first["files"] == "5")
        #expect(first["surface.openEditorTileID"] == "calendar")
        #expect(UUID(uuidString: first["surface.openEditorToken"] ?? "") != nil)
        fixture.controller.openCustomization()
        #expect(
            first["surface.openEditorToken"]
                != state.values(for: "notchShelf")["surface.openEditorToken"])
    }

    @Test func agentGlancesRequireMatchingMetricsAndRespectSavedWingWidth() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.state.publish([
            "surface.activeIDs": "[\"notchShelf\",\"herdr\"]",
            "surface.activeVersions": "{\"notchShelf\":\"1\",\"herdr\":\"1\"}",
        ])
        fixture.controller.synchronize()
        fixture.controller.layouts.update(.notch) {
            $0.notchLeadingGlance = .permissions
            $0.notchTrailingGlance = .none
            $0.notchWingWidth = 96
            $0.notchPrioritizePermissions = false
            $0.notchExpandPermissions = false
        }
        fixture.controller.recordSurfaceSnapshot(
            .init(
                providerID: "herdr",
                rows: [.init("unrelated", title: "Synthetic working agent", value: "Working")]))
        #expect(fixture.controller.leadingGlance == nil)
        #expect(fixture.controller.glanceWingWidth == 0)
        fixture.controller.recordSurfaceSnapshot(
            .init(
                providerID: "herdr",
                metrics: [.init("permissions", "Permissions", "0")]))
        #expect(fixture.controller.leadingGlance == nil)
        fixture.controller.recordSurfaceSnapshot(
            .init(
                providerID: "herdr",
                metrics: [.init("permissions", "Permissions", "2")]))
        #expect(fixture.controller.leadingGlance?.value == "2")
        #expect(fixture.controller.leadingGlance?.urgent == true)
        #expect(fixture.controller.glanceWingWidth == 96)
    }

    @Test func newPermissionExpansionIsOptInAndDoesNotReopenForTheSameRequest() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.state.publish([
            "surface.activeIDs": "[\"notchShelf\",\"herdr\"]",
            "surface.activeVersions": "{\"notchShelf\":\"1\",\"herdr\":\"1\"}",
        ])
        fixture.controller.synchronize()
        fixture.controller.layouts.update(.notch) {
            $0.notchLeadingGlance = .none
            $0.notchTrailingGlance = .none
            $0.notchExpandPermissions = true
            $0.notchPrioritizePermissions = false
        }
        #expect(fixture.controller.glanceProviderIDs == ["herdr"])
        let snapshot = SurfaceSnapshot(
            providerID: "herdr",
            metrics: [.init("permissions", "Permissions", "1")],
            rows: [.init("synthetic-request", title: "Synthetic tool", field: "approvals")])
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(fixture.controller.isExpanded)
        #expect(fixture.controller.activeTab == .agents)
        fixture.controller.collapseNow()
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(!fixture.controller.isExpanded)
        fixture.controller.layoutEditing = true
        fixture.controller.recordSurfaceSnapshot(
            .init(
                providerID: "herdr",
                metrics: [.init("permissions", "Permissions", "2")]))
        #expect(!fixture.controller.isExpanded)
    }

    @Test func savedMusicPreferenceClearsGlancesAndRejectsLateProviderData() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.state.publish([
            "surface.activeIDs": "[\"notchShelf\",\"music\"]",
            "surface.activeVersions": "{\"notchShelf\":\"1\",\"music\":\"1\"}",
        ])
        fixture.controller.synchronize()
        fixture.controller.layouts.update(.notch) {
            $0.notchLeadingGlance = .music
            $0.notchTrailingGlance = .none
            $0.notchExpandPermissions = false
            $0.notchPrioritizePermissions = false
        }
        let snapshot = SurfaceSnapshot(
            providerID: "music", rows: [.init("track", title: "Synthetic track")])
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(fixture.controller.leadingGlance?.source == .music)
        let request = NotchPreferenceRequest(key: AppStorageKeys.Notch.shelfShowMusic, value: "0")
        _ = try await fixture.controller.execute(
            "notch.settings.write", payload: JSONEncoder().encode(request))
        #expect(fixture.controller.glanceProviderIDs.isEmpty)
        #expect(fixture.controller.leadingGlance == nil)
        #expect(fixture.controller.surfaceSnapshots["music"] == nil)
        fixture.controller.recordSurfaceSnapshot(snapshot)
        #expect(fixture.controller.surfaceSnapshots["music"] == nil)
        fixture.controller.layouts.update(.notch) { $0.notchLeadingGlance = .automatic }
        #expect(!fixture.controller.glanceProviderIDs.contains("music"))
    }

    @MainActor private struct Fixture {
        let id = "notch-glance-tests-" + UUID().uuidString
        let root: URL
        let state: ExtensionSharedState
        let controller: NotchShelfController

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
            let defaults = try #require(UserDefaults(suiteName: id))
            defaults.set(false, forKey: AppStorageKeys.Notch.alertsEnabled)
            defaults.set(false, forKey: AppStorageKeys.Notch.shelfHaptics)
            state = ExtensionSharedState(root: root, namespace: id, owner: "host")
            try state.publish([
                "surface.activeIDs": "[\"notchShelf\",\"calendar\"]",
                "surface.activeVersions": "{\"notchShelf\":\"1\",\"calendar\":\"1\"}",
            ])
            controller = NotchShelfController(
                context: .init(defaults: defaults, sharedState: state), startsServices: false,
                root: root.appendingPathComponent("Shelf"), bluetoothPrivacyRequired: { false })
        }

        func clean() {
            controller.shutdown()
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
