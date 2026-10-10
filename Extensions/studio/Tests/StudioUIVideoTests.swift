import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import Foundation
import SwiftUI
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioUIVideoTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready())
    }

    @Test func originalVideoControlsEditNativeProjectAndReceiveEngineRenderedFrames() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("original.openscreen")
        _ = try VideoEditorService.create(at: source, title: "Synthetic timeline")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "intro")]), to: source,
            overwrite: true)
        let resources = StudioUIResources()
        let work = StudioUILongOperations()
        let sessions = StudioUIVideoSessions()
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.blob.") {
                return try resources.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.work.") {
                return try work.invoke(operation, payload: payload)
            }
            return try await sessions.execute(
                operation, payload: payload, resources: resources, work: work)
        }
        var sandboxBuilds = 0
        let editor = VideoEditorModel(
            previewBuilder: { _ in
                sandboxBuilds += 1
                throw StudioError.failed(
                    "A readonly controller must not construct a render pipeline.")
            }, facade: facade)
        editor.openProject(at: source)
        try await waitUntil { editor.remoteFrame != nil || editor.errorMessage != nil }
        #expect(editor.errorMessage == nil && editor.project?.title == "Synthetic timeline")
        #expect(editor.pipeline == nil && editor.previewMetadata != nil && sandboxBuilds == 0)
        let frame = try #require(editor.remoteFrame)
        #expect(frame.width > 0 && frame.height > 0)
        editor.seek(to: 0.5)
        editor.splitAtPlayhead()
        try await waitUntil {
            (try? VideoProject.open(source).clips.count) == 2 || editor.errorMessage != nil
        }
        #expect(editor.errorMessage == nil && editor.project?.clips.count == 2)
        editor.addZoom()
        editor.setZoomDepth(3)
        try await waitUntil {
            (try? VideoProject.open(source).zooms.count) == 1 || editor.errorMessage != nil
        }
        #expect(editor.errorMessage == nil)
        #expect(try VideoProject.open(source).zooms.first?.depth == 3)
        let host = NSHostingView(
            rootView: VideoEditorPage(model: editor, retained: true)
                .environment(\.studioFacade, facade).environment(\.colorScheme, .dark)
                .environment(\.automaticViewActionsEnabled, false).environment(
                    \.windowVisible, false))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(
            bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && TestWindowHost.exposedWindows.isEmpty)
        let output = root.appendingPathComponent("edited.mp4")
        let project = try VideoProject.open(source)
        let id = try #require(editor.remoteSessionID)
        let result: VideoDeliveryReport = try await facade.perform(
            "studio.ui.video.export",
            object: [
                "id": id.uuidString, "format": "video", "output": output.path,
                "settings": try facade.object(VideoDeliverySettings()),
                "quality": VideoExportQuality.source.rawValue,
                "fps": 15, "width": 0, "loop": true,
            ])
        #expect(result.bytes > 0 && result.duration > 0)
        #expect(project.clips.count == 2 && sandboxBuilds == 0)
        editor.close(); await work.stopAndWait(); await sessions.stopAndWait();
        resources.shutdown(); facade.stop()
        #expect(editor.pipeline == nil)
    }
    @Test func nativeOpenRelinksMissingMediaAndCopiesUnregisteredLibraryProjects() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("relink.openscreen")
        _ = try VideoEditorService.create(at: source, title: "Synthetic relink")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "source")]), to: source,
            overwrite: true)
        var document = try VideoProject.open(source)
        let asset = try #require(document.assets.first)
        document.relinkMedia(assetID: asset.id, to: root.appendingPathComponent("missing.mov"))
        try document.save(to: source)
        let original = try Data(contentsOf: source)
        let resources = StudioUIResources(); let work = StudioUILongOperations();
        let sessions = StudioUIVideoSessions()
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.blob.") {
                return try resources.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.work.") {
                return try work.invoke(operation, payload: payload)
            }
            return try await sessions.execute(
                operation, payload: payload, resources: resources, work: work)
        }
        let id = UUID()
        let info: StudioUIVideoOpenInfo = try await facade.read(
            "studio.ui.video.preflight", object: ["id": id.uuidString, "path": source.path])
        #expect(info.missingAssetIDs == [asset.id])
        let handle: StudioUIResource = try await facade.perform(
            "studio.ui.video.open",
            object: [
                "id": id.uuidString, "path": source.path, "revision": info.revision,
                "replacements": [asset.id: movie.path],
            ])
        let state: StudioUIVideoState = try await facade.download(handle)
        #expect(try state.project?.value.assets.first?.url == movie && state.preview != nil)
        #expect(try Data(contentsOf: source) == original)
        let library = VideoProject.openScreenLibraryURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let imported = library.appendingPathComponent("synthetic-\(UUID().uuidString).openscreen")
        defer { try? FileManager.default.removeItem(at: imported) }
        var copy = VideoProject.create(); copy.rename("Synthetic library copy");
        try copy.save(to: imported)
        let before = try Data(contentsOf: imported)
        let copied: StudioUIResource = try await facade.perform(
            "studio.ui.video.open", object: ["id": UUID().uuidString, "path": imported.path])
        let copiedState: StudioUIVideoState = try await facade.download(copied)
        let saved = try #require(copiedState.project?.fileURL)
        defer { try? FileManager.default.removeItem(at: saved) }
        #expect(saved != imported && saved.deletingLastPathComponent() == VideoProject.libraryURL)
        #expect(try Data(contentsOf: imported) == before)
        #expect(try VideoProject.open(saved).title == "Synthetic library copy")
        await work.stopAndWait(); await sessions.stopAndWait(); resources.shutdown(); facade.stop()
        VideoEditorOpenBridge.shared.shutdown()
    }

    @Test func commandOpenWaitsForCheckedRemoteRenderedAcknowledgement() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("mounted.openscreen")
        _ = try VideoEditorService.create(at: source, title: "Synthetic mounted editor")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "source")]), to: source,
            overwrite: true)
        let request = try VideoEditorService.prepareOpen(source)
        let bridge = VideoEditorOpenBridge.shared
        bridge.shutdown()
        var finished = false
        let opening = Task {
            try await bridge.open(request, timeout: 10); finished = true
        }
        try await waitUntil { bridge.pending != nil }
        #expect(!finished)
        let engine = StudioModel(loadsState: false)
        let resources = StudioUIResources(); let work = StudioUILongOperations();
        let sessions = StudioUIVideoSessions()
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.blob.") {
                return try resources.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.work.") {
                return try work.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.video.") {
                return try await sessions.execute(
                    operation, payload: payload, resources: resources, work: work)
            }
            return try await StudioUICommands.execute(operation, payload: payload, model: engine)
        }
        let remote = StudioModel(loadsState: false, facade: facade)
        let state: StudioUIState = try await facade.read("studio.ui.state")
        #expect(state.pendingOpen == request)
        remote.apply(state)
        try await waitUntil { remote.remoteCommandEditor != nil || remote.message != nil }
        #expect(
            remote.message == nil && !finished
                && remote.route == .commandVideoEditor(request.requestID))
        let editor = try #require(remote.remoteCommandEditor)
        #expect(editor.remoteFrame != nil && editor.pipeline == nil)
        try await editor.mountRemoteCommand(request)
        try await opening.value
        #expect(finished && bridge.pending == nil)
        remote.shutdown(); engine.shutdown(); await work.stopAndWait();
        await sessions.stopAndWait(); resources.shutdown(); bridge.shutdown()
    }

}
