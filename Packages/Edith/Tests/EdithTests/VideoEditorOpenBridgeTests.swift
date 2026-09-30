import Foundation
import Testing
@testable import Edith

@Suite @MainActor struct VideoEditorOpenBridgeTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var project = VideoProject.create(title: "Synthetic launch")
        let url = root.appendingPathComponent("sample.openscreen")
        try project.save(to: url)
        return url
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready())
    }

    @Test func successRequiresExactMountedModelAndRoutesRepeatedOpens() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let movie = try await VideoEditorServiceTests.movie(in: url.deletingLastPathComponent())
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "intro")]),
            to: url, overwrite: true)
        let original = try Data(contentsOf: url)
        var replies: [[String: Any]] = []
        var presentations = 0
        let bridge = VideoEditorOpenBridge(
            reply: { replies.append($0) }, present: { presentations += 1 })
        let studio = StudioModel(loadsState: false)
        let first = try VideoEditorService.prepareOpen(url)
        bridge.receive(first, deadline: Date().addingTimeInterval(5))
        try await waitUntil { bridge.pending != nil }
        #expect(replies.isEmpty)
        let prepared = try #require(bridge.pending)
        #expect(prepared.model.pipeline != nil)
        #expect(prepared.model.player.currentItem != nil)
        #expect(prepared.model.duration > 0)
        studio.openCommandProject(prepared)
        #expect(studio.route == .commandVideoEditor(first.requestID))
        #expect(studio.commandEditor?.model === prepared.model)
        let unrelated = VideoEditorModel()
        bridge.mounted(.init(request: first, model: unrelated))
        unrelated.close()
        #expect(replies.isEmpty)
        bridge.mounted(prepared)
        #expect(replies.count == 1)
        #expect(first.matches(replies[0]))
        #expect(replies[0]["state"] as? String == "opened")
        let second = try VideoEditorService.prepareOpen(url)
        bridge.receive(second, deadline: Date().addingTimeInterval(5))
        try await waitUntil { bridge.pending != nil }
        let next = try #require(bridge.pending)
        studio.openCommandProject(next)
        #expect(studio.route == .commandVideoEditor(second.requestID))
        bridge.mounted(prepared)
        #expect(replies.count == 1)
        bridge.mounted(next)
        #expect(replies.count == 2)
        #expect(second.matches(replies[1]))
        #expect(presentations == 2)
        #expect(try Data(contentsOf: url) == original)
        prepared.model.close()
        next.model.close()
    }

    @Test func concurrentRequestIsRejectedAndUnmountedRequestTimesOut() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var replies: [[String: Any]] = []
        let bridge = VideoEditorOpenBridge(reply: { replies.append($0) }, present: {})
        let first = try VideoEditorService.prepareOpen(url)
        let second = try VideoEditorService.prepareOpen(url)
        bridge.receive(first, deadline: Date().addingTimeInterval(0.1))
        bridge.receive(second, deadline: Date().addingTimeInterval(1))
        #expect(replies.first?["code"] as? String == "editor_busy")
        #expect(second.matches(try #require(replies.first)))
        try await waitUntil { replies.count == 2 }
        #expect(replies.last?["code"] as? String == "open_timeout")
        #expect(first.matches(try #require(replies.last)))
        #expect(bridge.pending == nil)
    }

    @Test func changesBeforeMountAndMissingMediaFailWithoutDialogs() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var replies: [[String: Any]] = []
        let bridge = VideoEditorOpenBridge(reply: { replies.append($0) }, present: {})
        let request = try VideoEditorService.prepareOpen(url)
        bridge.receive(request, deadline: Date().addingTimeInterval(5))
        try await waitUntil { bridge.pending != nil }
        let prepared = try #require(bridge.pending)
        var project = try VideoProject.open(url)
        project.rename("Changed synthetic project")
        try project.save(to: url)
        bridge.mounted(prepared)
        #expect(replies.last?["code"] as? String == "project_changed")
        prepared.model.close()
        project.addAsset(
            url.deletingLastPathComponent().appendingPathComponent("missing.mov"), duration: 1,
            width: 64, height: 64)
        try project.save(to: url)
        let missing = try VideoEditorService.prepareOpen(url)
        bridge.receive(missing, deadline: Date().addingTimeInterval(5))
        try await waitUntil { replies.count == 2 }
        #expect(replies.last?["code"] as? String == "missing_media")
        #expect(bridge.pending == nil)
    }

    @Test func unsavedEditorIsPreservedAndExpiredRequestsNeverPresent() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let active = VideoEditorModel()
        defer { active.close() }
        active.project = VideoProject.create(title: "Unsaved synthetic edit")
        active.mutate { $0.rename("Keep this edit") }
        #expect(active.hasUnsavedEdits)
        var replies: [[String: Any]] = []
        var presented = false
        let bridge = VideoEditorOpenBridge(
            reply: { replies.append($0) }, present: { presented = true })
        bridge.activeEditor = active
        let request = try VideoEditorService.prepareOpen(url)
        bridge.receive(request, deadline: Date().addingTimeInterval(5))
        #expect(replies.last?["code"] as? String == "editor_busy")
        #expect(active.project?.title == "Keep this edit")
        bridge.receive(request, deadline: Date().addingTimeInterval(-1))
        #expect(replies.last?["code"] as? String == "open_timeout")
        #expect(!presented)
    }
}
