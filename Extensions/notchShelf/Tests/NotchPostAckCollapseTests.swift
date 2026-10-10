import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized)
struct NotchPostAckCollapseTests {
    @Test func actualRuntimeDispatchRequiresExactCurrentExpandedDisplayAndPreservesOtherPanel()
        async throws
    {
        _ = TestWindowHost.application
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let otherPresentation = UUID()
        var owner: NotchShelfController?
        let runtime = ExtensionRuntime(
            contextSource: { fixture.context },
            connectedDisplays: {
                [42: CGSize(width: 1280, height: 900), 43: CGSize(width: 1600, height: 1000)]
            },
            createController: { context, displays in
                let controller = NotchShelfController(
                    context: context, startsServices: false,
                    root: fixture.root.appendingPathComponent("Shelf"), hostDisplays: displays,
                    bluetoothPrivacyRequired: { false })
                owner = controller
                return controller
            })
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        _ = runtime.execute(["operation": "start", "defaultsSuite": suite])
        let attach = NotchPanelAttach(
            ownershipID: fixture.ownership, version: "1",
            displays: [
                .init(
                    displayID: 42, presentationID: fixture.presentation, width: 1280, height: 900,
                    collapsedWidth: 150, collapsedHeight: 28, isBuiltin: true),
                .init(
                    displayID: 43, presentationID: otherPresentation, width: 1600, height: 1000,
                    collapsedWidth: 150, collapsedHeight: 28, isBuiltin: false),
            ])
        let batch = try JSONDecoder().decode(
            NotchPanelBatch.self, from: await invoke(runtime, "notch.panel.attach", attach))
        let controller = try #require(owner)
        controller.expand(on: 43)
        let snapshot = try await read(runtime, display: 43, presentation: otherPresentation)
        func action(
            display: UInt32 = 43, presentation: UUID? = nil, revision: UInt64? = nil,
            identity: NotchPanelIdentity? = nil
        ) -> NotchChromeAction {
            .init(
                identity: identity ?? batch.identity, displayID: display,
                presentationID: presentation ?? otherPresentation,
                revision: revision ?? snapshot.revision, operation: .collapse)
        }
        let invalid = [
            action(display: 42, presentation: fixture.presentation),
            action(presentation: UUID()),
            action(revision: snapshot.revision - 1),
            action(revision: snapshot.revision + 1),
            action(identity: .init(ownershipID: batch.identity.ownershipID, generation: UUID())),
            action(identity: .init(ownershipID: UUID(), generation: batch.identity.generation)),
        ]
        for request in invalid {
            await #expect(throws: (any Error).self) {
                _ = try await invoke(runtime, "notch.chrome.action", request)
            }
            #expect(controller.isExpanded(on: 43))
            #expect(
                try await read(runtime, display: 43, presentation: otherPresentation).revision
                    == snapshot.revision)
        }
        let otherBefore = try await read(runtime, display: 42, presentation: fixture.presentation)
        let reply = try JSONDecoder().decode(
            NotchChromeSnapshot.self, from: await invoke(runtime, "notch.chrome.action", action()))
        #expect(reply.identity == batch.identity && reply.revision > snapshot.revision)
        #expect(reply.panel.displayID == 43 && reply.panel.presentationID == otherPresentation)
        #expect(reply.panel.phase == .collapsed && !controller.isExpanded)
        let otherAfter = try await read(runtime, display: 42, presentation: fixture.presentation)
        #expect(otherAfter.panel.phase == otherBefore.panel.phase)
        #expect(otherAfter.panel.presentationID == otherBefore.panel.presentationID)
        await #expect(throws: (any Error).self) {
            _ = try await invoke(runtime, "notch.chrome.action", action())
        }
        await #expect(throws: (any Error).self) {
            _ = try await invoke(runtime, "notch.chrome.action", action(revision: reply.revision))
        }
        controller.expand(on: 42)
        let next = try await read(runtime, display: 42, presentation: fixture.presentation)
        await #expect(throws: (any Error).self) {
            _ = try await invoke(runtime, "notch.chrome.action", action(revision: next.revision))
        }
        #expect(controller.isExpanded(on: 42))
        try fixture.publish([:])
        await #expect(throws: (any Error).self) {
            _ = try await invoke(
                runtime, "notch.chrome.action",
                action(display: 42, presentation: fixture.presentation, revision: next.revision))
        }
        #expect(controller.ownedPanelCount == 0 && TestWindowHost.exposedWindows.isEmpty)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(!controller.isRunning && controller.ownedPanelCount == 0)
    }

    @Test func actualCollapsePreservesIssuedNativeTransferFilesAndPinsUntilExactCancellation()
        throws
    {
        _ = TestWindowHost.application
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let batch = try fixture.attach()
        let controller = fixture.bind()
        let item = try #require(controller.store.addText("synthetic retained native transfer"))
        controller.synchronizeShelfItems()
        controller.expand(on: 42)
        try fixture.engine.action(
            .init(
                identity: batch.identity, displayID: 42,
                presentationID: fixture.presentation, revision: fixture.engine.revision,
                operation: .share, itemID: item.id))
        let transfer = try #require(try fixture.engine.batch().transfers.first)
        try fixture.engine.action(
            .init(
                identity: batch.identity, displayID: 42,
                presentationID: fixture.presentation, revision: fixture.engine.revision,
                operation: .collapse))
        #expect(!controller.isExpanded)
        #expect(try fixture.engine.batch().transfers.first?.id == transfer.id)
        #expect(controller.store.addText("must remain pinned") == nil)
        #expect(
            try String(contentsOf: transfer.fileURLs[0], encoding: .utf8)
                == "synthetic retained native transfer")
        try fixture.engine.finishTransfer(
            .init(
                identity: batch.identity, id: transfer.id,
                completed: false, outside: false, error: "synthetic cancellation"))
        #expect(try fixture.engine.batch().transfers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURLs[0].path))
        #expect(controller.store.addText("selection drained") != nil)
        #expect(controller.ownedPanelCount == 0)
    }

    private func read(_ runtime: ExtensionRuntime, display: UInt32, presentation: UUID) async throws
        -> NotchChromeSnapshot
    {
        try JSONDecoder().decode(
            NotchChromeSnapshot.self,
            from: await invoke(
                runtime, "notch.chrome.read",
                NotchChromeRead(displayID: display, presentationID: presentation)))
    }

    private func invoke<T: Encodable>(_ runtime: ExtensionRuntime, _ command: String, _ request: T)
        async throws -> Data
    {
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            runtime.invoke(["token": UUID().uuidString, "command": command, "payload": payload]) {
                data, error in
                if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(
                        throwing: ExtensionPeerError.rejected(error as String? ?? "No reply"))
                }
            }
        }
    }
}
