import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchChromeClientTests {
    @Test func originalChromeUsesCheckedFacadeLayoutEditsAndMeasuredNativeSlots() async throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) {
            $0.tiles = [fixture.music, fixture.calendar, SurfaceTile(.clocks)]
        }
        controller.expand(on: 42)
        let client = client(fixture)
        defer { client.stop() }
        await client.refresh()
        #expect(client.isExpanded)
        #expect(client.visibleSurfaceLayout.visible == controller.visibleSurfaceLayout.visible)
        let rectangle = CGRect(x: 30, y: 80, width: 220, height: 160)
        let slot = try #require(client.slot(tile: fixture.music, kind: .card, rectangle: rectangle))
        client.report([slot])
        try await Task.sleep(for: .milliseconds(20))
        #expect(try fixture.engine.batch().states[0].slots == [slot])
        try fixture.engine.measure(
            .init(
                identity: try #require(fixture.engine.identity), displayID: 42,
                presentationID: fixture.presentation, slotID: slot.id,
                revision: fixture.engine.revision, height: 312, error: nil))
        await client.refresh()
        #expect(client.slotHeight(tile: fixture.music, kind: .card) == 312)
        client.chromeLayouts.update(.notch) {
            $0.move(fixture.calendar.id, before: fixture.music.id)
        }
        await client.drainActions()
        #expect(controller.surfaceLayout.visible.first == fixture.calendar)
        #expect(client.surfaceLayout == controller.surfaceLayout)
        client.chromeLayouts.undo(.notch)
        await client.drainActions()
        #expect(controller.surfaceLayout.visible.first == fixture.music)
        let view = NSHostingView(
            rootView: NotchShelfContentView(controller: client, displayID: 42).environment(
                \.automaticViewActionsEnabled, false))
        view.frame = CGRect(x: 0, y: 0, width: 604, height: 422)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        #expect(client.surfaceClient == nil)
        #expect(client.usesNativeSlots)
        #expect(!client.supportsNative(tile: SurfaceTile(.ability("database")), kind: .card))
    }

    @Test func stopCancelsLocalReadAndDiscardsLateOwnedPayload() async throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        _ = fixture.bind()
        var continuation: CheckedContinuation<Data, Error>?
        var cancelled = false
        let chrome = NotchChromeClient(
            displayID: 42, presentationID: fixture.presentation, namespace: fixture.id
        ) { _, _ in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation = $0 }
            } onCancel: {
                Task { @MainActor in cancelled = true }
            }
        }
        let task = Task { await chrome.refresh() }
        await Task.yield()
        chrome.stop()
        await Task.yield()
        let pending = try #require(continuation)
        pending.resume(
            returning: try JSONEncoder().encode(
                fixture.engine.chrome(.init(displayID: 42, presentationID: fixture.presentation))))
        await task.value
        #expect(cancelled)
        #expect(chrome.stopped)
        #expect(chrome.snapshot == nil)
        #expect(chrome.error == nil)
    }

    @Test func facadeRejectsCrossPresentationAndStaleGeneration() async throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        _ = fixture.bind()
        let other = NotchChromeClient(displayID: 42, presentationID: UUID(), namespace: fixture.id)
        { _, _ in
            try JSONEncoder().encode(
                fixture.engine.chrome(.init(displayID: 42, presentationID: fixture.presentation)))
        }
        defer { other.stop() }
        await other.refresh()
        #expect(other.snapshot == nil)
        #expect(other.error != nil)
        let chrome = client(fixture)
        defer { chrome.stop() }
        await chrome.refresh()
        try fixture.engine.detach(try #require(fixture.engine.identity))
        chrome.selectTab(.files)
        await chrome.drainActions()
        #expect(chrome.error != nil)
    }

    @Test func dragShareAndPromisedDropsRetainOriginalOwnedFilesUntilNativeCompletion() async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        let identity = try #require(fixture.engine.identity)
        _ = try ShelfMutationExecution.addText(
            "native transfer fixture", root: controller.store.root, sender: "fixture")
        _ = controller.store.reload()
        await controller.store.drainIndexRefreshes()
        controller.synchronizeShelfItems()
        let item = try #require(controller.items.first)
        let chrome = client(fixture)
        defer { chrome.stop() }
        await chrome.refresh()
        chrome.share(item)
        await chrome.drainActions()
        let shared = try #require(try fixture.engine.batch().transfers.first)
        #expect(shared.kind == .share)
        #expect(
            try String(contentsOf: shared.fileURLs[0], encoding: .utf8) == "native transfer fixture"
        )
        #expect(controller.store.addText("busy transfer") == nil)
        try fixture.engine.finishTransfer(
            .init(
                identity: identity, id: shared.id, completed: false, outside: false,
                error: "The native share picker could not open."))
        #expect(controller.store.addText("released transfer") != nil)
        #expect(try fixture.engine.batch().transfers.isEmpty)
        #expect(throws: (any Error).self) {
            try fixture.engine.finishTransfer(
                .init(
                    identity: identity, id: shared.id, completed: true, outside: false, error: nil))
        }
        let promise = NotchPanelPromise(
            identity: identity, displayID: 42, presentationID: fixture.presentation, id: UUID(),
            fileURL: nil, x: 50, y: 60)
        let directory = try fixture.engine.preparePromise(promise)
        let received = directory.appendingPathComponent("promised.txt")
        try Data("synthetic file promise".utf8).write(to: received)
        try fixture.engine.finishPromise(
            .init(
                identity: identity, displayID: 42, presentationID: fixture.presentation,
                id: promise.id, fileURL: received, x: 50, y: 60))
        #expect(
            controller.items.contains {
                $0.name == "promised.txt" && $0.position == CGPoint(x: 50, y: 60)
            })
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await chrome.refresh()
        chrome.beginExternalDrag(of: item)
        await chrome.drainActions()
        let drag = try #require(try fixture.engine.batch().transfers.first)
        #expect(drag.kind == .drag)
        fixture.engine.stop()
        #expect(controller.store.addText("stopped transfer") != nil)
        #expect(!FileManager.default.fileExists(atPath: drag.fileURLs[0].path))
    }

    private func client(_ fixture: NotchPanelFixture) -> NotchChromeClient {
        NotchChromeClient(
            displayID: 42, presentationID: fixture.presentation, namespace: fixture.id
        ) { operation, data in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            switch operation {
            case "notch.chrome.read":
                return try encoder.encode(
                    fixture.engine.chrome(decoder.decode(NotchChromeRead.self, from: data)))
            case "notch.chrome.action":
                let request = try decoder.decode(NotchChromeAction.self, from: data)
                try fixture.engine.action(request)
                return try encoder.encode(
                    fixture.engine.chrome(
                        .init(displayID: request.displayID, presentationID: request.presentationID))
                )
            case "notch.panel.geometry":
                try fixture.engine.geometry(decoder.decode(NotchPanelGeometry.self, from: data));
                return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
    }
}
