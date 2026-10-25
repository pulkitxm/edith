import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import EdithExtensionUI
@testable import CodeStatsExtension

@Suite(.serialized) @MainActor struct CodeStatsExportDeliveryTests {
    @Test func sharedCallbackRendersOriginalCardsAndUsesEngineAtomicDelivery() async throws {
        _ = NSApplication.shared
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow()
        let directory = harness.fixture.root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("synthetic.png")
        try Data("existing synthetic image".utf8).write(to: destination)
        var copied: Data?
        let owner = Owner(
            workflow: workflow,
            delivery: .init(chooseSaveURL: { _ in destination }, copy: { copied = $0 }))
        let client = try #require(
            ExtensionEngineClient(bridge: owner, presentationID: owner.presentation))
        let deck = CodeStatsExportDeck(
            snapshot: .init(report: CodeStatsPageFixture.report(.all)),
            remote: CodeStatsUIBridge(client: client))
        for save in [false, true] {
            let result = try #require(
                try await ExportCardDelivery.perform(
                    deck: deck, card: .highlights, save: save,
                    chooseSaveURL: { _ in
                        Issue.record("Facade selected a save path"); return nil
                    },
                    write: { _, _ in Issue.record("Facade wrote a file") },
                    copy: { _ in Issue.record("Facade copied an image") }))
            #expect(result.status.message == (save ? "Saved to synthetic.png" : "Image copied"))
            #expect(!result.status.failed && result.copied == !save)
            let request = try #require(owner.requests.last)
            #expect(request.name == deck.filename(for: .highlights) && request.save == save)
            let bitmap = try #require(NSBitmapImageRep(data: request.data))
            #expect(bitmap.pixelsWide == 2400 && bitmap.pixelsHigh == 1600)
            if save {
                #expect(try Data(contentsOf: destination) == request.data)
            } else {
                #expect(copied == request.data)
            }
        }
        #expect(owner.requests.count == 2)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["synthetic.png"]
        )
        client.invalidate()
        await owner.commands.shutdownAndWait()
        await workflow.shutdown()
    }

    @Test func invalidImagesNamesAndForeignPresentationsCannotReachDelivery() async throws {
        _ = NSApplication.shared
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow()
        var selections = 0
        var copies = 0
        let owner = Owner(
            workflow: workflow,
            delivery: .init(
                chooseSaveURL: { _ in
                    selections += 1; return nil
                }, copy: { _ in copies += 1 }))
        let client = try #require(
            ExtensionEngineClient(bridge: owner, presentationID: owner.presentation))
        let bridge = CodeStatsUIBridge(client: client)
        let image = try CodeStatsExportRenderer.pngData(
            snapshot: .init(report: CodeStatsPageFixture.report(.all)), card: .languages, scale: 1)
        for name in [
            "../synthetic.png", "folder\\synthetic.png", "synthetic\n.png", "synthetic.txt",
        ] {
            await #expect(throws: ExtensionEngineError.rejected) {
                _ = try await bridge.deliver(image, name: name, save: true)
            }
        }
        for data in [
            Data(image.prefix(8)), Data(),
            Data(image.prefix(8))
                + Data(repeating: 7, count: CodeStatsExportDelivery.maximumBytes - 7),
        ] {
            await #expect(throws: ExtensionEngineError.rejected) {
                _ = try await bridge.deliver(data, name: "synthetic.png", save: false)
            }
        }
        let foreign = try #require(ExtensionEngineClient(bridge: owner, presentationID: UUID()))
        await #expect(throws: ExtensionEngineError.rejected) {
            _ = try await CodeStatsUIBridge(client: foreign).deliver(
                image, name: "synthetic.png", save: false)
        }
        for save in [false, true] {
            let request = CodeStatsPNGDelivery(data: image, name: "synthetic.png", save: save)
            let error = await #expect(throws: ExtensionPeerError.self) {
                _ = try await CodeStatsUIBridge.execute(
                    "codeStats.ui.export", payload: JSONEncoder().encode(request),
                    workflow: workflow)
            }
            switch error {
            case .invalidRequest?: break
            default: Issue.record("Live fixture delivery was not refused")
            }
        }
        #expect(selections == 0 && copies == 0)
        foreign.invalidate(); client.invalidate()
        await owner.commands.shutdownAndWait()
        await workflow.shutdown()
    }

    @Test func cancelledSelectionDrainsEngineAndCannotReplaceAnExistingPNG() async throws {
        _ = NSApplication.shared
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow()
        let destination = harness.fixture.root.appendingPathComponent("synthetic.png")
        let original = Data("existing synthetic image".utf8)
        try original.write(to: destination)
        var selection: CheckedContinuation<URL?, Never>?
        var cancelled = false
        var copies = 0
        let owner = Owner(
            workflow: workflow,
            delivery: .init(
                chooseSaveURL: { _ in
                    let result = await withCheckedContinuation { selection = $0 }
                    cancelled = Task.isCancelled
                    return result
                }, copy: { _ in copies += 1 }))
        let client = try #require(
            ExtensionEngineClient(bridge: owner, presentationID: owner.presentation))
        let deck = CodeStatsExportDeck(
            snapshot: .init(report: CodeStatsPageFixture.report(.all)),
            remote: CodeStatsUIBridge(client: client))
        let operation = Task {
            try await ExportCardDelivery.perform(
                deck: deck, card: .rhythm, save: true,
                chooseSaveURL: { _ in
                    Issue.record("Facade selected a save path"); return nil
                },
                copy: { _ in Issue.record("Facade copied an image") })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while selection == nil {
            guard ContinuousClock.now < deadline else { throw ExtensionEngineError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        selection?.resume(returning: destination)
        await owner.commands.shutdownAndWait()
        #expect(cancelled && copies == 0 && owner.cancelled.count == 1)
        #expect(try Data(contentsOf: destination) == original)
        client.invalidate()
        await workflow.shutdown()
    }

    @Test func cancelledSaveAndDisabledEngineLeaveDeliveryUntouched() async throws {
        _ = NSApplication.shared
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow()
        var selections = 0
        var copies = 0
        let owner = Owner(
            workflow: workflow,
            delivery: .init(
                chooseSaveURL: { _ in
                    selections += 1; return nil
                }, copy: { _ in copies += 1 }))
        let client = try #require(
            ExtensionEngineClient(bridge: owner, presentationID: owner.presentation))
        let image = try CodeStatsExportRenderer.pngData(
            snapshot: .init(report: CodeStatsPageFixture.report(.all)), card: .rhythm, scale: 1)
        let bridge = CodeStatsUIBridge(client: client)
        #expect(
            try await bridge.deliver(image, name: "synthetic.png", save: true) == "Save cancelled")
        await owner.commands.shutdownAndWait()
        await #expect(throws: ExtensionEngineError.rejected) {
            _ = try await bridge.deliver(image, name: "synthetic.png", save: false)
        }
        client.invalidate()
        await #expect(throws: ExtensionEngineError.unavailable) {
            _ = try await bridge.deliver(image, name: "synthetic.png", save: true)
        }
        #expect(selections == 1 && copies == 0)
        await workflow.shutdown()
    }

    @MainActor private final class Owner: NSObject {
        let presentation = UUID()
        let commands = ExtensionCommandRegistry()
        let workflow: CodeStatsWorkflow
        let delivery: CodeStatsExportDelivery
        var requests: [CodeStatsPNGDelivery] = []
        var cancelled: [String] = []

        init(workflow: CodeStatsWorkflow, delivery: CodeStatsExportDelivery) {
            self.workflow = workflow; self.delivery = delivery
        }

        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            guard request.presentationID == presentation,
                request.operation == "codeStats.ui.export",
                (try? request.validate()) != nil
            else {
                completion(
                    (try? ExtensionEngineWire.encode(
                        ExtensionEngineReply(token: request.token, ok: false))) ?? Data())
                return
            }
            if let delivery = try? JSONDecoder().decode(
                CodeStatsPNGDelivery.self, from: request.payload)
            {
                requests.append(delivery)
            }
            commands.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ],
                completion: { payload, error in
                    completion(
                        (try? ExtensionEngineWire.encode(
                            ExtensionEngineReply(
                                token: request.token, ok: error == nil,
                                payload: payload as Data? ?? Data()))) ?? Data())
                }
            ) { [self] command, payload in
                try await CodeStatsUIBridge.execute(
                    command, payload: payload, workflow: workflow, exportDelivery: delivery)
            }
        }

        @objc func cancel(_ token: String) {
            cancelled.append(token)
            commands.cancel(token)
        }
    }
}
