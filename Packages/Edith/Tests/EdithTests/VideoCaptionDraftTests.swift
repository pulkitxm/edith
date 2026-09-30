import Foundation
import Testing
@testable import Edith

@MainActor @Suite struct VideoCaptionDraftTests {
    @Test func pendingFieldsSurviveRemountAndFailedApplyUntilSavedOrDiscarded() async throws {
        let (directory, url, initial) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = initial
        project.addText("SYNTHETIC", startMs: 0, endMs: 1000)
        let id = try #require(project.annotations.first?.id)
        try project.setCaptionStyle(id, style: VideoCaptionStyleTests.styled)
        try project.save(to: url)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = project
        let caption = try #require(model.project?.annotations.first)
        let draft = model.captionDraft(caption)
        draft.refresh()
        #expect(!model.blocksCommandOpen)
        draft.values["fontSize"] = "104"
        draft.values["start"] = "0"
        #expect(!model.blocksCommandOpen)
        let baseline = draft.values
        draft.values["text"] = "EDITED"
        draft.values["fontFamily"] = "Missing Synthetic Family 9472"
        draft.values["start"] = "invalid"
        #expect(
            model.pendingViewEditIDs == [
                "caption.\(id).text", "caption.\(id).style", "caption.\(id).time",
            ])
        draft.apply("style")
        #expect(draft.failure != nil)
        #expect(draft.values["fontFamily"] == "Missing Synthetic Family 9472")
        #expect(model.captionDraft(caption) === draft)
        draft.refresh()
        #expect(draft.values["text"] == "EDITED")
        var replies: [[String: Any]] = []
        let bridge = VideoEditorOpenBridge(reply: { replies.append($0) }, present: {})
        bridge.activeEditor = model
        bridge.receive(
            try VideoEditorService.prepareOpen(url), deadline: Date().addingTimeInterval(5))
        #expect(replies.last?["code"] as? String == "editor_busy")
        draft.apply("text")
        #expect(!model.pendingViewEditIDs.contains("caption.\(id).text"))
        #expect(try VideoProject.open(url).annotations.first?.text == "EDITED")
        draft.values["text"] = "😀"
        draft.apply("text")
        #expect(draft.failure != nil && model.pendingViewEditIDs.contains("caption.\(id).text"))
        #expect(try VideoProject.open(url).annotations.first?.text == "EDITED")
        draft.values["text"] = "EDITED"
        draft.apply("time")
        #expect(model.pendingViewEditIDs.contains("caption.\(id).time"))
        draft.values["fontFamily"] = baseline["fontFamily"]
        draft.values["start"] = baseline["start"]
        #expect(!model.blocksCommandOpen)
        draft.values["json"] = "{"
        draft.values["fontSize"] = "not a number"
        draft.apply("json")
        draft.apply("style")
        #expect(model.blocksCommandOpen && draft.failure != nil)
        draft.refresh(discard: true)
        #expect(!model.blocksCommandOpen)
        draft.values["fontSize"] = "112"
        draft.apply("style")
        #expect(draft.failure == nil && model.pendingViewEditIDs.isEmpty)
        #expect(try VideoProject.open(url).annotations.first?.captionStyle?.fontSize == 112)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.pipeline == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        draft.values["start"] = "0.2"
        draft.values["end"] = "0.8"
        draft.apply("time")
        #expect(draft.failure == nil && model.pendingViewEditIDs.isEmpty)
        #expect(try VideoProject.open(url).annotations.first?.startMs == 400)
        draft.values["end"] = "0.201"
        draft.apply("time")
        #expect(draft.failure != nil && model.pendingViewEditIDs.contains("caption.\(id).time"))
        draft.refresh(discard: true)
        draft.values["text"] = "SAVE FAILURE"
        model.project?.fileURL = directory
        draft.apply("text")
        draft.refresh()
        #expect(draft.failure != nil && model.pendingViewEditIDs.contains("caption.\(id).text"))
        #expect(draft.values["text"] == "SAVE FAILURE" && model.blocksCommandOpen)
        model.project?.fileURL = url
        draft.apply("text")
        #expect(draft.failure == nil && model.pendingViewEditIDs.isEmpty)
        draft.values["text"] = "UNSAVED"
        model.openProject(at: directory.appendingPathComponent("missing.openscreen"))
        #expect(model.captionDraft(caption) === draft && draft.values["text"] == "UNSAVED")
        model.removeCaption(id)
        #expect(model.captionDrafts.isEmpty && model.pendingViewEditIDs.isEmpty)
    }
}
