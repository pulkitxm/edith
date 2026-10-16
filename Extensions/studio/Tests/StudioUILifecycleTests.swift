import AppKit
import AVFoundation
import EdithExtensionSupport
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioUILifecycleTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready())
    }

    @Test func cancellationBeforeStartReplyPreventsNativeImagePublication() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("synthetic.png")
        let target = root.appendingPathComponent("cancelled.png")
        let original = Data("Synthetic existing output".utf8)
        try original.write(to: target)
        let engine = StudioModel(loadsState: false); let resources = StudioUIResources();
        let work = StudioUILongOperations()
        var pending: CheckedContinuation<Void, Never>?
        var reply: CheckedContinuation<Data, Error>?
        var delivery: Task<Data, Error>?
        var cleaned = 0
        var reached = false
        var rejected = false
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.blob.") {
                return try resources.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.work.") {
                if operation != "studio.ui.work.read" { cleaned += 1 }
                return try work.invoke(operation, payload: payload)
            }
            if operation == "studio.ui.image.export" {
                delivery = Task {
                    reached = true
                    await withCheckedContinuation { pending = $0 }
                    do {
                        let result = try await StudioUIImageCommands.execute(
                            operation, payload: payload, model: engine, resources: resources,
                            work: work)
                        reply?.resume(returning: result); reply = nil
                        return result
                    } catch {
                        rejected = true; reply?.resume(throwing: error); reply = nil; throw error
                    }
                }
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { reply = $0 }
                } onCancel: {
                    Task { @MainActor in
                        reply?.resume(throwing: CancellationError()); reply = nil
                    }
                }
            }
            throw ExtensionPeerError.invalidRequest
        }
        let document = ImageEditDocument(source: source)
        let handle = try await facade.upload(document)
        let task = Task {
            let _: URL = try await facade.perform(
                "studio.ui.image.export",
                object: ["document": try facade.object(handle), "output": target.path])
        }
        try await waitUntil { reached }
        task.cancel()
        do {
            try await task.value; Issue.record("Cancelled start unexpectedly completed.")
        } catch is CancellationError {}
        try await waitUntil { cleaned >= 2 }
        pending?.resume(); pending = nil
        if let delivery {
            do {
                _ = try await delivery.value;
                Issue.record("Cancelled delivery unexpectedly started.")
            } catch is CancellationError {}
        }
        #expect(rejected)
        await work.stopAndWait()
        #expect(try Data(contentsOf: target) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
                !$0.hasPrefix(".studio-image-")
            })
        facade.stop(); resources.shutdown(); await engine.stopAndWait()
    }

    @Test func facadeQueuesConcurrentReadsAndDisablingCancelsBoundedOwnedWork() async throws {
        let engine = StudioModel(loadsState: false)
        let reply = try await StudioUICommands.execute(
            "studio.ui.state", payload: Data("{}".utf8), model: engine)
        var pending: [CheckedContinuation<Data, Error>] = []
        var inFlight = 0; var maximum = 0; var invalidations = 0
        let facade = StudioUIFacade(
            invoke: { _, _ in
                inFlight += 1; maximum = max(maximum, inFlight)
                defer { inFlight -= 1 }
                return try await withCheckedThrowingContinuation { pending.append($0) }
            }, invalidate: { invalidations += 1 })
        let tasks = (0..<12).map { _ in
            Task { let _: StudioUIState = try await facade.read("studio.ui.state") }
        }
        try await waitUntil { pending.count == 6 }
        #expect(maximum == 6)
        facade.stop()
        for continuation in pending { continuation.resume(returning: reply) }
        for task in tasks {
            do { try await task.value; Issue.record("Disabled read completed.") } catch {}
        }
        #expect(maximum == 6 && invalidations == 1 && facade.state == nil)
        await engine.stopAndWait()
    }

    @Test func realVideoExportCancellationPreservesOutputAndStopsBeforeDisableCompletes()
        async throws
    {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        var project = VideoProject.create()
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        let first = try #require(project.clips.first?.id)
        for _ in 0..<59 { _ = project.duplicate(clipID: first) }
        let source = root.appendingPathComponent("long.openscreen")
        try project.save(to: source)
        let originalProject = try Data(contentsOf: source)
        let output = root.appendingPathComponent("preserved.mp4")
        let originalOutput = Data("Synthetic existing movie output".utf8)
        try originalOutput.write(to: output)
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
        let opened: StudioUIResource = try await facade.perform(
            "studio.ui.video.open", object: ["id": id.uuidString, "path": source.path])
        let _: StudioUIVideoState = try await facade.download(opened)
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "format": "video", "output": output.path,
            "settings": try facade.object(VideoDeliverySettings()),
            "quality": VideoExportQuality.source.rawValue, "fps": 15, "width": 0, "loop": true,
        ])
        let start = try JSONDecoder().decode(
            StudioUIOperationState.self,
            from: await sessions.execute(
                "studio.ui.video.export", payload: payload, resources: resources, work: work))
        var current = start
        let token = try JSONSerialization.data(withJSONObject: ["token": start.token.uuidString])
        let deadline = ContinuousClock.now + .seconds(15)
        while current.progress == 0, current.phase == "running", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            current = try JSONDecoder().decode(
                StudioUIOperationState.self,
                from: work.invoke("studio.ui.work.read", payload: token))
        }
        #expect(current.phase == "running" && current.progress > 0 && current.progress < 1)
        _ = try work.invoke("studio.ui.work.cancel", payload: token)
        let stopped = ContinuousClock.now
        await work.stopAndWait(); await sessions.stopAndWait()
        #expect(stopped.duration(to: .now) < .seconds(5))
        #expect(
            try Data(contentsOf: output) == originalOutput
                && Data(contentsOf: source) == originalProject)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
                !$0.hasPrefix(".video-export-")
            })
        resources.shutdown(); facade.stop(); VideoEditorOpenBridge.shared.shutdown()
    }
}
