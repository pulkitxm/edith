import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import Foundation
import SwiftUI
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioUIEditorTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready())
    }

    @Test func originalImageEditorLoadsRendersAndExportsThroughOwnedNativeServices() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("synthetic.png")
        let original = try Data(contentsOf: source)
        let engine = StudioModel(loadsState: false)
        let resources = StudioUIResources()
        let work = StudioUILongOperations()
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.blob.") {
                return try resources.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.work.") {
                return try work.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.image.") {
                return try await StudioUIImageCommands.execute(
                    operation, payload: payload, model: engine,
                    resources: resources, work: work)
            }
            return try await StudioUICommands.execute(operation, payload: payload, model: engine)
        }
        let remote = StudioModel(loadsState: false, facade: facade)
        let editor = remote.imageEditor(for: source)
        editor.load()
        try await waitUntil { editor.preview != nil || editor.loadError != nil }
        #expect(
            editor.loadError == nil && editor.source?.originalSize == CGSize(width: 64, height: 64))
        editor.edit { $0.crop = StudioRect(x: 0, y: 0, width: 0.5, height: 1) }
        try await waitUntil { editor.renderedDocument == editor.document || editor.status != nil }
        #expect(editor.preview?.width == 32 && editor.preview?.height == 64)
        let host = NSHostingView(
            rootView: StudioImageEditorView(model: remote, editor: editor)
                .environment(\.studioFacade, facade).environment(\.colorScheme, .dark)
                .environment(\.automaticViewActionsEnabled, false).environment(
                    \.windowVisible, false))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        #expect(TestWindowHost.exposedWindows.isEmpty)
        let output = root.appendingPathComponent("edited.png")
        editor.save(to: output, studio: remote)
        try await waitUntil { !editor.isSaving }
        #expect(editor.lastSaved == output && editor.savedDocument == editor.document)
        #expect(StudioImageIO.info(output)?.width == 32 && StudioImageIO.info(output)?.height == 64)
        #expect(try Data(contentsOf: source) == original)
        remote.shutdown()
        await work.stopAndWait()
        resources.shutdown()
        await engine.stopAndWait()
        await #expect(throws: ExtensionEngineError.self) { try await facade.facts(source) }
    }

    @Test func cancelledNativeImageExportPreservesExistingOutputAndLeavesNoTemporaryFile()
        async throws
    {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("synthetic.png")
        let target = root.appendingPathComponent("preserved.png")
        let original = Data("Synthetic existing output".utf8)
        try original.write(to: target)
        let cancellation = WorkCancellation()
        cancellation.cancel()
        #expect(throws: StudioError.cancelled) {
            try ImageEditRenderer.export(
                document: ImageEditDocument(source: source), to: target,
                cancelled: { cancellation.isCancelled })
        }
        #expect(try Data(contentsOf: target) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasPrefix(".studio-image-") })
        let work = StudioUILongOperations()
        let state = try work.start { _ in
            try await BlockingWork.perform {
                try ImageEditRenderer.export(
                    document: ImageEditDocument(source: source), to: target,
                    cancelled: { cancellation.isCancelled })
            }
            return Data("{}".utf8)
        }
        await work.stopAndWait()
        #expect(try Data(contentsOf: target) == original)
        let payload = try JSONSerialization.data(withJSONObject: ["token": state.token.uuidString])
        #expect(throws: ExtensionPeerError.self) {
            try work.invoke("studio.ui.work.read", payload: payload)
        }
    }

    @Test func mediaTransferRejectsForeignHandlesOverwritesAndDisabledReads() throws {
        let resources = StudioUIResources()
        defer { resources.shutdown() }
        let bytes = Data(repeating: 0xff, count: StudioUIResources.chunkBytes + 17)
        let handle = try resources.store(bytes)
        let encoder = JSONEncoder()
        func payload(_ handle: StudioUIResource, offset: Int) throws -> Data {
            let value = try JSONSerialization.jsonObject(with: encoder.encode(handle))
            return try JSONSerialization.data(withJSONObject: ["handle": value, "offset": offset])
        }
        let first = try JSONDecoder().decode(
            Data.self,
            from: resources.invoke("studio.ui.blob.read", payload: payload(handle, offset: 0)))
        #expect(first == bytes.prefix(StudioUIResources.chunkBytes))
        let rest = try JSONDecoder().decode(
            Data.self,
            from: resources.invoke(
                "studio.ui.blob.read", payload: payload(handle, offset: first.count)))
        #expect(rest == bytes.suffix(17))
        #expect(throws: ExtensionPeerError.self) {
            try resources.invoke(
                "studio.ui.blob.read",
                payload: payload(
                    StudioUIResource(token: handle.token, length: handle.length + 1), offset: 0))
        }
        #expect(throws: ExtensionPeerError.self) {
            try resources.invoke("studio.ui.blob.read", payload: payload(handle, offset: -1))
        }
        #expect(try resources.consume(handle) == bytes)
        #expect(throws: ExtensionPeerError.self) {
            try resources.invoke("studio.ui.blob.read", payload: payload(handle, offset: 0))
        }
        resources.shutdown()
        #expect(throws: ExtensionPeerError.self) { try resources.store(Data()) }
    }
}
