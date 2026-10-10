import AppKit
import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchPanelAssemblyTests {
    @Test func realOffscreenPanelContainsOriginalChromeAndNativeSiblingCard() async throws {
        let fixture = HostNotchStateFixture()
        let owner = NotchTestScenes()
        var presentations = 0
        let assembly = HostNotchPanelAssembly(
            create: owner.create, present: { _ in presentations += 1 })
        let closeObserver = NotchPanelCloseObserver()
        assembly.panel.delegate = closeObserver
        let state = fixture.state()
        try assembly.accept(state, admission: fixture.admission())
        await settle { assembly.attachedCount == 2 }
        #expect(!assembly.panel.isVisible)
        #expect(!assembly.panel.canBecomeMain)
        #expect(!assembly.panel.canBecomeKey)
        #expect(assembly.panel.styleMask.contains(.nonactivatingPanel))
        #expect(assembly.panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(assembly.panel.level.rawValue == NSWindow.Level.statusBar.rawValue + 8)
        #expect(assembly.panel.frame == state.panelFrame(display: fixture.display))
        #expect(assembly.container.children.count == 2)
        #expect(
            assembly.container.view.hitTest(
                assembly.container.view.convert(
                    CGPoint(x: 8, y: 100), to: assembly.container.view.superview)) == nil)
        #expect(
            assembly.container.view.hitTest(
                assembly.container.view.convert(
                    CGPoint(x: 250, y: 100), to: assembly.container.view.superview)) != nil)
        #expect(
            owner.requests.contains { $0.extensionID == "notchShelf" && $0.section == "panel.1" })
        let card = try #require(owner.leases.first { $0.request.extensionID == "music" })
        #expect(card.controller.parent === assembly.container)
        #expect(card.controller.view.frame == state.slots.first?.rectangle.frame)
        #expect(card.controller.view.superview?.isFlipped == true)
        #expect(card.controller.view.superview !== assembly.container.view)
        #expect(presentations == 1)
        try await assembly.stop()
        #expect(assembly.container.children.isEmpty)
        #expect(closeObserver.closed)
        #expect(!assembly.panel.isVisible)
        #expect(assembly.attachedCount == 0)
        #expect(assembly.pendingCleanupCount == 0)
        #expect(owner.leases.allSatisfy { $0.closed })
    }

    @Test func geometryChangesReuseSceneButCustomizedTileChangesReplaceIt() async throws {
        let fixture = HostNotchStateFixture()
        let owner = NotchTestScenes()
        let assembly = HostNotchPanelAssembly(create: owner.create, present: { _ in })
        let first = fixture.state()
        try assembly.accept(first, admission: fixture.admission())
        await settle { assembly.attachedCount == 2 }
        let slot = try #require(first.slots.first)
        let moved = HostNotchNativeSlot(
            id: slot.id, providerID: slot.providerID, providerVersion: slot.providerVersion,
            kind: slot.kind, tile: slot.tile,
            rectangle: .init(x: 510, y: 80, width: 280, height: 180))
        try assembly.accept(
            try advanced(first, revision: 2, slots: [moved]),
            admission: fixture.admission(previousRevision: 1))
        #expect(owner.requests.count == 2)
        #expect(
            owner.leases.first { $0.request.extensionID == "music" }?.controller.view.frame
                == moved.rectangle.frame)
        var tile = slot.tile
        tile.dense = true
        let changed = HostNotchNativeSlot(
            id: slot.id, providerID: slot.providerID, providerVersion: slot.providerVersion,
            kind: slot.kind, tile: tile, rectangle: moved.rectangle)
        try assembly.accept(
            try advanced(first, revision: 3, slots: [changed]),
            admission: fixture.admission(previousRevision: 2, layout: .init(tiles: [tile])))
        await settle {
            owner.requests.count == 3 && assembly.attachedCount == 2
                && assembly.pendingCleanupCount == 0
        }
        let music = owner.leases.filter { $0.request.extensionID == "music" }
        #expect(music.count == 2)
        #expect(music[0].request.presentationID != music[1].request.presentationID)
        #expect(music[0].closed)
        #expect(music[1].request.surface?.tile.dense == true)
        try await assembly.stop()
    }

    @Test func privacyDisableAndOcclusionWithdrawAllNativeWorkImmediately() async throws {
        let fixture = HostNotchStateFixture()
        let owner = NotchTestScenes()
        let assembly = HostNotchPanelAssembly(create: owner.create, present: { _ in })
        let first = fixture.state()
        try assembly.accept(first, admission: fixture.admission())
        await settle { assembly.attachedCount == 2 }
        assembly.synchronize(
            activeVersions: ["notchShelf": "1.0.0", "music": "1.0.0"], hiddenWidgets: [.music])
        #expect(assembly.attachedCount == 1)
        await settle { owner.leases.first { $0.request.extensionID == "music" }?.closed == true }
        let hidden = try advanced(first, revision: 2, visible: false, slots: [])
        try assembly.accept(hidden, admission: fixture.admission(previousRevision: 1))
        #expect(assembly.attachedCount == 0)
        #expect(assembly.panel.ignoresMouseEvents)
        #expect(!assembly.panel.acceptsKeyFocus)
        await settle { owner.leases.allSatisfy { $0.closed } }
        try await assembly.stop()
    }

    @Test func cancelledLateSceneCannotReturnAfterPanelIsHidden() async throws {
        let fixture = HostNotchStateFixture()
        let owner = NotchTestScenes()
        let gate = NotchTestGate()
        owner.gate = gate
        let assembly = HostNotchPanelAssembly(create: owner.create, present: { _ in })
        try assembly.accept(fixture.state(), admission: fixture.admission())
        await settle { gate.waiting }
        assembly.hide()
        gate.release()
        await settle { owner.leases.count == 2 && owner.leases.allSatisfy { $0.closed } }
        #expect(assembly.container.children.isEmpty)
        #expect(assembly.attachedCount == 0)
        try await assembly.stop()
    }

    @Test func failedNativeShutdownRetainsOwnershipAndRetryCompletesCleanup() async throws {
        let fixture = HostNotchStateFixture()
        let owner = NotchTestScenes()
        owner.failClose = true
        let assembly = HostNotchPanelAssembly(create: owner.create, present: { _ in })
        try assembly.accept(fixture.state(), admission: fixture.admission())
        await settle { assembly.attachedCount == 2 }
        await #expect(throws: HostWorkerError.rejected) { try await assembly.stop() }
        #expect(assembly.attachedCount == 0)
        #expect(assembly.pendingCleanupCount == 2)
        #expect(owner.leases.allSatisfy { !$0.closed && $0.controller.parent == nil })
        owner.failClose = false
        try await assembly.stop()
        #expect(assembly.pendingCleanupCount == 0)
        #expect(assembly.failures.isEmpty)
        #expect(owner.leases.allSatisfy { $0.closed })
        #expect(throws: HostNotchPanelError.staleState) {
            try assembly.accept(fixture.state(), admission: fixture.admission())
        }
    }

    @Test func boundedHeightFeedbackOnlyComesFromCurrentAttachedNativeSlot() async throws {
        let fixture = HostNotchStateFixture()
        let owner = NotchTestScenes()
        var heights: [Double] = []
        let assembly = HostNotchPanelAssembly(
            create: owner.create, present: { _ in },
            measure: { _, height in heights.append(height) })
        let state = fixture.state()
        try assembly.accept(state, admission: fixture.admission())
        await settle { assembly.attachedCount == 2 }
        let music = try #require(owner.leases.first { $0.request.extensionID == "music" })
        music.measuredHeight?(220)
        music.measuredHeight?(.nan)
        music.measuredHeight?(1800)
        #expect(heights == [220])
        assembly.hide()
        music.measuredHeight?(240)
        #expect(heights == [220])
        try await assembly.stop()
    }

    private func advanced(
        _ state: HostNotchPanelState, revision: UInt64, visible: Bool = true,
        slots: [HostNotchNativeSlot]
    ) throws -> HostNotchPanelState {
        HostNotchPanelState(
            contractVersion: state.contractVersion, ownershipID: state.ownershipID,
            version: state.version, revision: revision, displayID: state.displayID,
            presentationID: state.presentationID, phase: state.phase, activeTab: state.activeTab,
            shapeWidth: state.shapeWidth, shapeHeight: state.shapeHeight, visible: visible,
            acceptsPointer: state.acceptsPointer, acceptsKeyFocus: state.acceptsKeyFocus,
            slots: slots)
    }
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class NotchPanelCloseObserver: NSObject, NSWindowDelegate {
    private(set) var closed = false
    func windowWillClose(_ notification: Notification) { closed = true }
}

@MainActor
private final class NotchTestScenes {
    var requests: [HostExtensionContentRequest] = []
    var leases: [HostNotchSceneLease] = []
    var failClose = false
    var gate: NotchTestGate?
    init() { _ = TestWindowHost.application }
    func create(_ request: HostExtensionContentRequest) async throws -> HostNotchSceneLease {
        requests.append(request)
        if request.extensionID == "music", let gate { await gate.wait() }
        let controller = NSViewController()
        controller.view = NSView()
        let lease = HostNotchSceneLease(
            request: request, controller: controller, update: { _, _, _ in },
            release: { [self] in
                if failClose { throw HostWorkerError.rejected }
            })
        leases.append(lease)
        return lease
    }
}

@MainActor
private final class NotchTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
