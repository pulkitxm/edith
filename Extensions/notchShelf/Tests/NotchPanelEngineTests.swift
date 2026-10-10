import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchPanelEngineTests {
    @Test func attachBeforeStartSuppressesOwnedPanelsAndPreservesOriginalLayout() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let batch = try fixture.attach()
        #expect(batch.states.count == 1)
        #expect(batch.states[0].phase == .collapsed)
        #expect(batch.states[0].shapeWidth == 150)
        let controller = fixture.bind()
        #expect(controller.ownedPanelCount == 0)
        controller.layouts.update(.notch) { $0.tiles = [fixture.music, fixture.calendar] }
        controller.expand(on: 42)
        let state = try fixture.engine.batch().states[0]
        #expect(state.phase == .expanded)
        #expect(state.activeTab == "home")
        #expect(controller.surfaceLayout.tiles == [fixture.music, fixture.calendar])
        #expect(try fixture.attach().identity == batch.identity)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "contractVersion", "ownershipID", "version", "revision", "displayID",
                "presentationID", "phase", "activeTab", "shapeWidth", "shapeHeight", "visible",
                "acceptsPointer", "acceptsKeyFocus", "slots", "capacityWidth", "capacityHeight",
            ])
    }

    @Test func lostAttachReplyRecoversOnlyExactOwnerAndCleanupSurvivesDisable() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let first = try fixture.attach()
        let controller = fixture.bind()
        controller.expand(on: 42)
        try fixture.publish([:])
        #expect(try fixture.attach().identity == first.identity)
        let display = try #require(fixture.engine.displays[42])
        #expect(throws: (any Error).self) {
            try fixture.engine.attach(.init(ownershipID: UUID(), version: "1", displays: [display]))
        }
        var stale = display
        stale = .init(
            displayID: 42, presentationID: UUID(), width: display.width, height: display.height,
            collapsedWidth: 150, collapsedHeight: 28, isBuiltin: true)
        #expect(throws: (any Error).self) {
            try fixture.engine.attach(
                .init(ownershipID: fixture.ownership, version: "1", displays: [stale]))
        }
        #expect(throws: (any Error).self) {
            try fixture.engine.chrome(.init(displayID: 42, presentationID: fixture.presentation))
        }
        try fixture.engine.detach(first.identity)
        try fixture.engine.detach(first.identity)
        #expect(!fixture.engine.attached)
        #expect(controller.ownedPanelCount == 0)
    }

    @Test func geometryAdmitsExactSavedTilesAndRejectsStaleDisabledAndOutOfBoundsSlots() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = [fixture.music, fixture.calendar] }
        controller.expand(on: 42)
        let slot = fixture.slot(fixture.music)
        try fixture.geometry([slot])
        #expect(try fixture.engine.batch().states[0].slots == [slot])
        var rectangle = slot.rectangle
        rectangle.width = 3000
        let oversized = NotchPanelSlot(
            id: slot.id, providerID: "music", providerVersion: "1", kind: .card,
            tile: fixture.music, rectangle: rectangle)
        #expect(throws: (any Error).self) { try fixture.geometry([oversized]) }
        var changed = fixture.music
        changed.showTitle.toggle()
        #expect(throws: (any Error).self) { try fixture.geometry([fixture.slot(changed)]) }
        #expect(throws: (any Error).self) { try fixture.geometry([slot, slot]) }
        try fixture.publish(["notchShelf": "1", "calendar": "1"])
        controller.synchronize()
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(throws: (any Error).self) { try fixture.geometry([slot]) }
        let identity = try #require(fixture.engine.identity)
        try fixture.engine.detach(identity)
        #expect(throws: (any Error).self) {
            try fixture.engine.chrome(.init(displayID: 42, presentationID: fixture.presentation))
        }
        #expect(controller.ownedPanelCount == 0)
    }

    @Test func eventDrivenWaitReturnsOwnedRevisionAndCancellationReleasesOnlyItsWait() async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let batch = try fixture.attach()
        let controller = fixture.bind()
        let identity = batch.identity
        let revision = fixture.engine.revision
        let waiting = Task {
            try await fixture.engine.wait(
                .init(identity: identity, revision: revision, timeout: 25))
        }
        await Task.yield()
        controller.expand(on: 42)
        let updated = try await waiting.value
        #expect(updated.revision > revision)
        #expect(updated.states[0].phase == .expanded)
        let pending = Task {
            try await fixture.engine.wait(
                .init(identity: identity, revision: updated.revision, timeout: 25))
        }
        await Task.yield()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let timeout = try await fixture.engine.wait(
            .init(identity: identity, revision: fixture.engine.revision, timeout: 0.01))
        #expect(timeout.revision == fixture.engine.revision)
        let stopped = Task {
            try await fixture.engine.wait(
                .init(identity: identity, revision: fixture.engine.revision, timeout: 25))
        }
        await Task.yield()
        fixture.engine.stop()
        await #expect(throws: CancellationError.self) { try await stopped.value }
        await #expect(throws: (any Error).self) {
            try await fixture.engine.wait(.init(identity: identity, revision: 0, timeout: 1))
        }
    }

    @Test func pointerGateAndMeasuredProviderHeightKeepOriginalDwellAndShelfResizing() async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let batch = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) {
            $0.tiles = [fixture.music]; $0.notchHorizontal = true
        }
        let pointer = NotchPanelPointer(
            identity: batch.identity, displayID: 42, presentationID: fixture.presentation, x: 640,
            y: 10, buttons: 0, option: false, draggingFiles: false)
        try fixture.engine.pointer(pointer)
        #expect(!controller.isExpanded)
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.isExpanded(on: 42))
        let slot = fixture.slot(fixture.music)
        try fixture.geometry([slot])
        try fixture.engine.measure(
            .init(
                identity: batch.identity, displayID: 42, presentationID: fixture.presentation,
                slotID: slot.id, revision: fixture.engine.revision, height: 312, error: nil))
        let snapshot = try fixture.engine.chrome(
            .init(displayID: 42, presentationID: fixture.presentation))
        #expect(snapshot.heights[slot.id] == 312)
        #expect(throws: (any Error).self) {
            try fixture.engine.measure(
                .init(
                    identity: batch.identity, displayID: 42, presentationID: fixture.presentation,
                    slotID: UUID(), revision: fixture.engine.revision, height: 100, error: nil))
        }
        #expect(throws: (any Error).self) {
            try fixture.engine.pointer(
                .init(
                    identity: batch.identity, displayID: 42, presentationID: UUID(), x: 640, y: 10,
                    buttons: 0, option: false, draggingFiles: false))
        }
        #expect(throws: (any Error).self) {
            try fixture.engine.pointer(
                .init(
                    identity: batch.identity, displayID: 42, presentationID: fixture.presentation,
                    x: .infinity, y: 10, buttons: 0, option: false, draggingFiles: false))
        }
    }

    @Test func chromeActionsMutateOriginalOwnedShelfAndRejectAnotherGeneration() async throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        _ = try ShelfMutationExecution.addText(
            "synthetic parked note", root: controller.store.root, sender: "fixture")
        _ = controller.store.reload()
        await controller.store.drainIndexRefreshes()
        controller.synchronizeShelfItems()
        let item = try #require(controller.items.first)
        let identity = try #require(fixture.engine.identity)
        try fixture.engine.action(
            .init(
                identity: identity, displayID: 42, presentationID: fixture.presentation,
                revision: fixture.engine.revision, operation: .select, itemID: item.id))
        #expect(controller.selectedIDs == [item.id])
        let stale = NotchPanelIdentity(ownershipID: identity.ownershipID, generation: UUID())
        #expect(throws: (any Error).self) {
            try fixture.engine.action(
                .init(
                    identity: stale, displayID: 42, presentationID: fixture.presentation,
                    revision: fixture.engine.revision, operation: .remove, itemID: item.id))
        }
        #expect(
            FileManager.default.fileExists(
                atPath: controller.store.root.appendingPathComponent(item.name).path))
        try fixture.engine.action(
            .init(
                identity: identity, displayID: 42, presentationID: fixture.presentation,
                revision: fixture.engine.revision, operation: .remove, itemID: item.id))
        #expect(try ShelfMutationExecution.snapshot(root: controller.store.root).items.isEmpty)
    }

}

@MainActor final class NotchPanelFixture {
    let id = "notch-panel-fixture-" + UUID().uuidString
    let root: URL
    let defaults: UserDefaults
    let context: SurfaceHostContext
    let presentation = UUID()
    let ownership = UUID()
    let music = SurfaceTile(.music)
    let calendar = SurfaceTile(.calendar)
    let engine: NotchPanelEngine
    var controller: NotchShelfController?
    init(
        cameraFactory: @escaping @MainActor () -> NotchCameraEngine = {
            NotchCameraEngine(hardware: NativeNotchCameraHardware())
        }
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        defaults = try #require(UserDefaults(suiteName: id))
        defaults.set(false, forKey: AppStorageKeys.Notch.shelfHaptics)
        defaults.set(false, forKey: AppStorageKeys.Notch.alertsEnabled)
        context = SurfaceHostContext(
            defaults: defaults, sharedState: .init(root: root, namespace: id, owner: "host"))
        engine = NotchPanelEngine(
            context: context, connectedDisplays: { [42: CGSize(width: 1280, height: 900)] },
            cameraFactory: cameraFactory)
        try publish(["notchShelf": "1", "music": "1", "calendar": "1"])
    }
    func publish(_ versions: [String: String]) throws {
        try context.sharedState.publish([
            "surface.activeIDs": String(
                decoding: JSONEncoder().encode(Array(versions.keys)), as: UTF8.self),
            "surface.activeVersions": String(
                decoding: JSONEncoder().encode(versions), as: UTF8.self),
        ])
    }
    @discardableResult func attach() throws -> NotchPanelBatch {
        try engine.attach(
            .init(
                ownershipID: ownership, version: "1",
                displays: [
                    .init(
                        displayID: 42, presentationID: presentation, width: 1280, height: 900,
                        collapsedWidth: 150, collapsedHeight: 28, isBuiltin: true)
                ]))
    }
    func bind() -> NotchShelfController {
        let controller = NotchShelfController(
            context: context, startsServices: false, root: root.appendingPathComponent("Shelf"),
            hostDisplays: Array(engine.displays.values), bluetoothPrivacyRequired: { false })
        self.controller = controller
        engine.bind(controller)
        return controller
    }
    func slot(_ tile: SurfaceTile) -> NotchPanelSlot {
        .init(
            id: UUID(), providerID: tile.widget.providerIDs.sorted()[0], providerVersion: "1",
            kind: .card, tile: tile, rectangle: .init(x: 30, y: 80, width: 220, height: 160))
    }
    func geometry(_ slots: [NotchPanelSlot]) throws {
        try engine.geometry(
            .init(
                identity: try #require(engine.identity), displayID: 42,
                presentationID: presentation, revision: engine.revision,
                layout: try #require(controller).surfaceLayout, slots: slots))
    }
    func clean() {
        engine.stop(); controller?.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: id)
        try? FileManager.default.removeItem(at: root)
    }
}
