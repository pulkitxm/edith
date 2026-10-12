import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import Foundation
import Testing
@testable import StudioExtension

@Suite @MainActor struct VideoEditorLiveSyncTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready())
    }

    @Test func atomicHeadlessEditsUpdateTimelineCaptionsAndPreviewWithoutReopening() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        let original = try Data(contentsOf: movie)
        let url = directory.appendingPathComponent("live.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Synthetic live edit")
        let added = try await VideoEditorService.apply(
            .init(operations: [.addMedia(path: movie.path, name: "shot")]),
            to: url, overwrite: true)
        let clipID = try #require(added.aliases["shot"])
        let model = VideoEditorModel()
        defer { model.close() }
        try await model.loadCommandProject(VideoEditorService.prepareOpen(url))
        model.seek(to: 0.1)
        try await waitUntil { abs(model.player.currentTime().seconds - 0.1) < 0.02 }
        model.selectedClipID = clipID
        model.titleDraft = model.project?.title
        let first = try await VideoEditorService.apply(
            .init(operations: [
                .rename(title: "First agent edit"),
                .trim(clipID: clipID, start: 0.1, end: 0.6),
                .text(content: "LIVE SYNTHETIC CAPTION", start: 0.1, end: 0.3),
            ]), to: url, overwrite: true)
        try await waitUntil {
            model.project?.fileRevision?.value.hexDigest == first.revision
                && abs(model.player.currentTime().seconds - 0.1) < 0.02
        }
        #expect(model.project?.title == "First agent edit")
        #expect(model.project?.annotations.first?.text == "LIVE SYNTHETIC CAPTION")
        #expect(abs(model.duration - 0.5) < 0.01)
        #expect(model.player.currentItem?.status == .readyToPlay)
        #expect(model.selectedClipID == clipID)
        #expect(abs(model.playhead - 0.1) < 0.02)
        #expect(model.titleDraft == nil)
        #expect(!model.hasUnsavedEdits)
        let second = try await VideoEditorService.apply(
            .init(operations: [.rename(title: "Second agent edit")]),
            to: url, overwrite: true)
        try await waitUntil {
            model.project?.fileRevision?.value.hexDigest == second.revision
        }
        #expect(model.project?.title == "Second agent edit")
        #expect(try Data(contentsOf: movie) == original)
    }

    @Test func draftsRemainIntactAndRefreshResumesWhenTheyAreDiscarded() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Saved title")
        let model = VideoEditorModel()
        defer { model.close() }
        try await model.loadCommandProject(VideoEditorService.prepareOpen(url))
        model.titleDraft = "Unsaved local draft"
        model.setPendingViewEdit("caption.synthetic", hasChanges: true)
        let changed = try await VideoEditorService.apply(
            .init(operations: [.rename(title: "Headless agent title")]),
            to: url, overwrite: true)
        try await waitUntil { model.externalSyncMessage != nil }
        #expect(model.project?.title == "Saved title")
        #expect(model.titleDraft == "Unsaved local draft")
        #expect(model.pendingViewEditIDs == ["caption.synthetic"])
        #expect(try VideoProject.open(url).title == "Headless agent title")
        model.titleDraft = "Saved title"
        model.setPendingViewEdit("caption.synthetic", hasChanges: false)
        try await waitUntil {
            model.project?.fileRevision?.value.hexDigest == changed.revision
        }
        #expect(model.externalSyncMessage == nil)
        #expect(model.project?.title == "Headless agent title")
        #expect(model.pipeline == nil)
    }

    @Test func invalidReplacementPreservesCurrentEditorAndRecoversOnNextValidWrite() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replacement.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Keep the loaded edit")
        let model = VideoEditorModel()
        defer { model.close() }
        try await model.loadCommandProject(VideoEditorService.prepareOpen(url))
        let original = try Data(contentsOf: url)
        try Data("not a project".utf8).write(to: url, options: .atomic)
        try await waitUntil { model.externalSyncMessage != nil }
        #expect(model.project?.title == "Keep the loaded edit")
        try original.write(to: url, options: .atomic)
        try await waitUntil { model.externalSyncMessage == nil }
        model.close()
        _ = try await VideoEditorService.apply(
            .init(operations: [.rename(title: "Edited while closed")]),
            to: url, overwrite: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.project?.title == "Keep the loaded edit")
        #expect(try VideoProject.open(url).title == "Edited while closed")
    }

    @Test func editBeforeWatcherInstallationIsDetectedWithoutAnotherWrite() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("initial.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Captured before the edit")
        let captured = try VideoProject.open(url)
        let changed = try await VideoEditorService.apply(
            .init(operations: [.rename(title: "Changed before watching")]),
            to: url, overwrite: true)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = captured
        try await waitUntil {
            model.project?.fileRevision?.value.hexDigest == changed.revision
        }
        #expect(model.project?.title == "Changed before watching")
    }

    @Test func closeDuringProjectPreparationDoesNotRestartWatchingOrPlayback() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("closing.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Closed during preparation")
        let model = VideoEditorModel()
        model.openProject(at: url)
        model.close()
        _ = try await VideoEditorService.apply(
            .init(operations: [.rename(title: "Headless edit after closing")]),
            to: url, overwrite: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.project == nil)
        #expect(model.player.currentItem == nil)
        #expect(model.pipeline == nil)
        #expect(model.externalSyncMessage == nil)
        #expect(try VideoProject.open(url).title == "Headless edit after closing")
    }
}
