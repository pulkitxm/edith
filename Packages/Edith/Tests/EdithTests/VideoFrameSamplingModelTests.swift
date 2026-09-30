import Foundation
import Testing

@testable import Edith

@Suite @MainActor struct VideoFrameSamplingModelTests {
    @Test func nativeSelectionPersistsSupportsUndoAndCanResetAnUnsupportedTrim() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.project(in: directory)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = try VideoEditorService.open(url)
        let id = try #require(model.project?.clips.first?.id)
        model.selectedClipID = id
        try await model.setFrameSampling(.nearest, clipID: id)
        #expect(try VideoEditorService.open(url).clips[0].frameSampling == .nearest)
        #expect(model.project?.clips[0].start == 2 && model.project?.clips[0].end == 3)
        #expect(model.canUndo && model.pendingViewEditIDs.isEmpty)
        model.undo()
        #expect(try VideoEditorService.open(url).clips[0].frameSampling == .hold)
        model.redo()
        #expect(try VideoEditorService.open(url).clips[0].frameSampling == .nearest)
        model.mutate { $0.trim(clipID: id, start: 2, end: 5) }
        try await model.setFrameSampling(.hold, clipID: id)
        let recovered = try VideoEditorService.open(url)
        #expect(try recovered.clips[0].frameSampling == .hold)
        #expect(recovered.clips[0].start == 2 && recovered.clips[0].end == 5)
        #expect(model.selectedClipID == id)
        #expect(model.pendingViewEditIDs.isEmpty && !model.hasUnsavedEdits)
    }

    @Test func rejectedNativeSelectionKeepsModeProjectAndUndoHistoryUnchanged() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.project(in: directory)
        var project = try VideoEditorService.open(url)
        let id = project.clips[0].id
        project.trim(clipID: id, start: 4, end: 5)
        try project.save(to: url)
        let original = try Data(contentsOf: url)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = project
        model.selectedClipID = id
        do {
            try await model.setFrameSampling(.nearest, clipID: id)
            Issue.record("The native model accepted an unavailable sampling phase.")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_frame_sampling")
            #expect(error.message.contains("extends beyond available source media"))
        }
        #expect(try model.project?.clips[0].frameSampling == .hold)
        #expect(try Data(contentsOf: url) == original)
        #expect(model.selectedClipID == id)
        #expect(!model.canUndo && !model.hasUnsavedEdits && !model.blocksCommandOpen)
        #expect(model.pendingViewEditIDs.isEmpty)
    }

    @Test func holdRecoveryIsNotBlockedByAnotherInvalidNearestClip() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.project(in: directory)
        var project = try VideoEditorService.open(url)
        let first = project.clips[0].id
        let duplicated = project.duplicate(clipID: first)
        let second = try #require(duplicated)
        for id in [first, second] {
            try project.setFrameSampling(.nearest, clipID: id)
            project.trim(clipID: id, start: 4, end: 5)
        }
        try project.save(to: url)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = project
        for id in [first, second] {
            model.selectedClipID = id
            try await model.setFrameSampling(.hold, clipID: id)
            let restored = try VideoEditorService.open(url)
            #expect(try restored.clips.first { $0.id == id }?.frameSampling == .hold)
        }
        #expect(model.pendingViewEditIDs.isEmpty)
    }

    private static func project(in directory: URL) async throws -> URL {
        let source = directory.appendingPathComponent("source.mov")
        try await VideoFrameSamplingTests.fixture(
            source, times: VideoFrameSamplingTests.timestamps("oneTwenty"))
        let url = directory.appendingPathComponent("edit.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Synthetic native sampling")
        _ = try await VideoEditorService.apply(
            .init(operations: [
                .addMedia(path: source.path, name: "shot"),
                .videoSettings(settings: .init(width: 32, height: 32)),
                .trim(clipID: "shot", start: 2, end: 3),
            ]), to: url, overwrite: true)
        return url
    }
}
