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
                root: root.appendingPathComponent("Shelf"))
        }

        func clean() {
            controller.shutdown()
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
