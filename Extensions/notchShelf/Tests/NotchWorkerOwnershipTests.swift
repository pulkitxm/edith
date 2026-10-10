import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@Suite @MainActor
struct NotchWorkerOwnershipTests {
    private func fixture(_ active: [String: String] = ["notchShelf": "1.0.0"])
        throws -> (NotchShelfController, SurfaceHostContext, URL, String)
    {
        let id = "notch-worker-tests-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let defaults = try #require(UserDefaults(suiteName: id))
        defaults.set(false, forKey: AppStorageKeys.Notch.alertsEnabled)
        defaults.set(false, forKey: AppStorageKeys.Notch.shelfHaptics)
        let state = ExtensionSharedState(root: root, namespace: id, owner: "host")
        let data = try JSONEncoder().encode(Array(active.keys).sorted())
        let versions = try JSONEncoder().encode(active)
        try state.publish([
            "surface.activeIDs": String(decoding: data, as: UTF8.self),
            "surface.activeVersions": String(decoding: versions, as: UTF8.self),
        ])
        let context = SurfaceHostContext(defaults: defaults, sharedState: state)
        return (
            NotchShelfController(
                context: context, startsServices: false, root: root.appendingPathComponent("Shelf"),
                bluetoothPrivacyRequired: { false }),
            context, root, id
        )
    }

    private func cleanup(_ controller: NotchShelfController, _ root: URL, _ id: String) {
        controller.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: id)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func providerTabsFollowRunningVersionsAndKeepIntrinsicTools() throws {
        let (controller, context, root, id) = try fixture([
            "notchShelf": "1", "clipboard": "1", "herdr": "1", "audioMixer": "1",
        ])
        defer { cleanup(controller, root, id) }
        #expect(
            Set(controller.visibleTabs) == [.home, .agents, .files, .clipboard, .audio, .camera])
        controller.selectTab(.clipboard)
        #expect(controller.activeTab == .clipboard)
        try context.sharedState.publish([
            "surface.activeIDs": "[\"notchShelf\"]",
            "surface.activeVersions": "{\"notchShelf\":\"2\"}",
        ])
        controller.synchronize()
        #expect(controller.activeTab == .home)
        #expect(Set(controller.visibleTabs) == [.home, .files, .camera])
        #expect(controller.requests.versions == ["notchShelf": "2"])
        controller.selectTab(.agents)
        #expect(controller.activeTab == .home)
    }

    @Test func savedLayoutAndTabOrderSurviveUnavailableProviders() throws {
        let (controller, context, root, id) = try fixture()
        defer { cleanup(controller, root, id) }
        let tile = SurfaceTile(.ability("clipboard"))
        controller.layouts.update(.notch) {
            $0.tiles = [tile, SurfaceTile(.clocks)]
            $0.tabOrder = ["files", "clipboard", "home", "camera", "audio", "agents", "browser"]
            $0.hiddenTabs = ["camera"]
            $0.notchLeadingGlance = .nextMeeting
        }
        #expect(controller.visibleTabs == [.files, .home])
        #expect(controller.layouts.notch.tiles.contains(tile))
        #expect(controller.leadingGlance == nil)
        let restored = SurfaceLayoutStore(defaults: context.defaults)
        #expect(restored.notch == controller.layouts.notch)
        #expect(restored.notch.tiles.contains(tile))
    }

    @Test func snapshotRejectsOtherProvidersAndArbitraryActions() async throws {
        let (controller, _, root, id) = try fixture()
        defer { cleanup(controller, root, id) }
        let request = SurfaceSnapshotRequest(
            target: .home, tile: SurfaceTile(.ability("notchShelf")))
        let response = try await controller.execute(
            "surface.snapshot", payload: request.encoded(providerID: "notchShelf"))
        let snapshot = try SurfaceSnapshot.decode(response, providerID: "notchShelf")
        #expect(snapshot.metrics == [.init("files", "Files", "0")])
        #expect(snapshot.actions.map(\.id) == ["customize"])
        let invalid = SurfaceActionRequest(snapshot: request, actionID: "/bin/sh")
        await #expect(throws: (any Error).self) {
            _ = try await controller.execute(
                "surface.perform", payload: invalid.encoded(providerID: "notchShelf"))
        }
        let other = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.calendar))
        await #expect(throws: (any Error).self) {
            _ = try await controller.execute(
                "surface.snapshot", payload: other.encoded(providerID: "calendar"))
        }
    }

    @Test func disabledNotchAndStoppedControllerCannotRestoreRequests() throws {
        let (controller, context, root, id) = try fixture()
        defer { cleanup(controller, root, id) }
        controller.shutdown()
        try context.sharedState.publish([
            "surface.activeIDs": "[\"notchShelf\",\"calendar\"]",
            "surface.activeVersions": "{\"notchShelf\":\"2\",\"calendar\":\"1\"}",
        ])
        controller.synchronize()
        #expect(controller.requests.versions.isEmpty)
        #expect(controller.requests.pendingCount == 0)
        #expect(controller.surfaceSnapshots.isEmpty)
    }

    @Test func shelfSnapshotMasksFilenamesBeforeTheProcessBoundary() async throws {
        let (controller, context, root, id) = try fixture()
        defer { cleanup(controller, root, id) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notch-mock-" + UUID().uuidString))
        pasteboard.setString("synthetic shelf note", forType: .string)
        #expect(controller.handleDrop(from: pasteboard))
        #expect(!controller.items.isEmpty)
        let presenter = ExtensionSharedState(
            root: context.sharedState.root, namespace: context.sharedState.namespace,
            owner: "presenter")
        try presenter.publish(["active": "1", "blurShelf": "1"])
        controller.synchronize()
        let request = SurfaceSnapshotRequest(
            target: .home, tile: SurfaceTile(.ability("notchShelf")))
        let data = try await controller.execute(
            "surface.snapshot", payload: request.encoded(providerID: "notchShelf"))
        let result = try SurfaceSnapshot.decode(data, providerID: "notchShelf")
        #expect(result.rows.isEmpty)
        #expect(result.message == "Hidden while presenting")
        #expect(controller.leadingGlance == nil)
    }
}
