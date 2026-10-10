import AVFoundation
import EdithExtensionSupport
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioBackgroundExportTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready())
    }

    private func facade(
        _ runtime: ExtensionRuntime, invalidate: @escaping @MainActor () -> Void = {}
    ) -> StudioUIFacade {
        StudioUIFacade(
            invoke: { command, payload in
                let token = UUID().uuidString
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        runtime.invoke(
                            ["token": token, "command": command, "payload": payload] as NSDictionary
                        ) { data, failure in
                            if let data {
                                continuation.resume(returning: data as Data)
                            } else if Task.isCancelled {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(
                                    throwing: StudioUIOperationFailure(
                                        message: failure as String? ?? "The engine request failed.")
                                )
                            }
                        }
                    }
                } onCancel: {
                    Task { @MainActor in
                        _ = runtime.execute(
                            ["operation": "cancelCommand", "token": token] as NSDictionary)
                    }
                }
            }, invalidate: invalidate)
    }

    @Test func closingReadonlyEditorDetachesExportAndReopenedControlsReceiveNativeResult()
        async throws
    {
        let runtime = ExtensionRuntime()
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        _ = runtime.execute(["operation": "start", "defaultsSuite": suite] as NSDictionary)
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 320, height: 180, frameRateNumerator: 30)
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        let clip = try #require(project.clips.first?.id)
        for _ in 0..<119 { _ = project.duplicate(clipID: clip) }
        let source = root.appendingPathComponent("background.openscreen")
        try project.save(to: source)
        let original = try Data(contentsOf: source)
        let output = root.appendingPathComponent("background.mp4")
        var invalidations = 0
        let old = facade(runtime, invalidate: { invalidations += 1 })
        let editor = VideoEditorModel(facade: old)
        editor.openProject(at: source)
        try await waitUntil { editor.remoteFrame != nil || editor.errorMessage != nil }
        #expect(editor.errorMessage == nil)
        let id = try #require(editor.remoteSessionID)
        old.exporter.start(to: output) { progress in
            let _: VideoDeliveryReport = try await old.perform(
                "studio.ui.video.export",
                object: [
                    "id": id.uuidString, "format": "video", "output": output.path,
                    "settings": try old.object(VideoDeliverySettings()),
                    "quality": VideoExportQuality.source.rawValue, "fps": 15, "width": 0,
                    "loop": true,
                ], progress: progress)
        }
        try await waitUntil { (old.exporter.job?.progress ?? 0) > 0 }
        #expect(old.exporter.isExporting)
        editor.close()
        old.stop()
        try await waitUntil { invalidations == 1 }
        let status = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
        #expect(status?["preventsQuit"] as? Bool == true)
        let reopened = facade(runtime)
        reopened.refresh()
        try await waitUntil { reopened.state?.export != nil || reopened.failure != nil }
        #expect(reopened.failure == nil && reopened.exporter.job?.destination == output)
        let token = try #require(reopened.state?.export?.token)
        reopened.observe()
        try await waitUntil { reopened.exporter.job?.phase == .finished }
        let report = try #require(reopened.exporter.job?.report)
        #expect(report.bytes > 0 && report.frameCount == 3600 && abs(report.duration - 120) < 0.01)
        #expect(report.sha256 == (try await VideoDeliveryReport.inspect(output)).sha256)
        #expect(try Data(contentsOf: source) == original)
        #expect(reopened.exporter.job?.id == token)
        reopened.exporter.clear()
        try await waitUntil {
            reopened.refresh(); return reopened.state?.export == nil
        }
        #expect(reopened.exporter.job == nil)
        reopened.stop()
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        let disabled = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
        #expect(
            disabled?["running"] as? Bool == false && disabled?["preventsQuit"] as? Bool == false)
    }
}
