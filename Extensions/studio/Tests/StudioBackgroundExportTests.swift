import AVFoundation
import EdithExtensionSupport
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioBackgroundExportTests {
    private final class Requests {
        var pending: [UUID: String] = [:]
        var recent: [String] = []

        func finished(_ token: UUID, data: Data?, failure: String?) {
            let command = pending.removeValue(forKey: token) ?? "unknown"
            var details = failure ?? "ok"
            if let data,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                for field in ["phase", "progress", "failure", "studioFailure"] {
                    if let value = object[field] { details += " \(field)=\(value)" }
                }
            }
            recent.append("\(command): \(details)")
            if recent.count > 16 { recent.removeFirst() }
        }

        var snapshot: String {
            "pending=\(pending.values.sorted()) recent=\(recent)"
        }
    }

    private func waitUntil(
        _ stage: String, stallLimit: Duration = .seconds(30), overallLimit: Duration = .seconds(30),
        progress: () -> Double = { 0 }, diagnostics: () -> String,
        sourceLocation: SourceLocation = #_sourceLocation, _ ready: () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        var advanced = started
        var latest = progress()
        print("studio background export: waiting for \(stage)")
        while !ready() {
            let now = ContinuousClock.now
            let current = progress()
            if current > latest {
                latest = current
                advanced = now
            }
            if now - started >= overallLimit || now - advanced >= stallLimit { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = ready()
        let details =
            "stage=\(stage) elapsed=\(started.duration(to: .now)) "
            + "sinceProgress=\(advanced.duration(to: .now)) progress=\(latest) \(diagnostics())"
        print("studio background export: \(details)")
        try #require(satisfied, Comment(rawValue: details), sourceLocation: sourceLocation)
    }

    private func diagnostics(
        _ runtime: ExtensionRuntime, requests: Requests, facade: StudioUIFacade,
        editor: VideoEditorModel? = nil
    ) -> String {
        let status = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
        let job = facade.exporter.job
        let state = facade.state?.export
        return
            "running=\(status?["running"] ?? "nil") preventsQuit=\(status?["preventsQuit"] ?? "nil") "
            + "stopped=\(facade.isStopped) facadeFailure=\(facade.failure ?? "nil") "
            + "activeWork=\(facade.activeWork.count) retainedWork=\(facade.retainedWork.count) "
            + "jobPhase=\(String(describing: job?.phase)) jobProgress=\(job?.progress ?? -1) "
            + "nativePhase=\(state?.phase ?? "nil") nativeProgress=\(state?.progress ?? -1) "
            + "nativeFailure=\(state?.failure ?? "nil") reportFrames=\(job?.report?.frameCount ?? -1) "
            + "session=\(editor?.remoteSessionID != nil) frame=\(editor?.remoteFrame != nil) "
            + "clips=\(editor?.project?.clips.count ?? -1) preparing=\(editor?.isPreparingPreview ?? false) "
            + "editorError=\(editor?.errorMessage ?? "nil") \(requests.snapshot)"
    }

    private func facade(
        _ runtime: ExtensionRuntime, requests: Requests,
        invalidate: @escaping @MainActor () -> Void = {}
    ) -> StudioUIFacade {
        StudioUIFacade(
            invoke: { command, payload in
                let token = UUID()
                requests.pending[token] = command
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        runtime.invoke(
                            ["token": token.uuidString, "command": command, "payload": payload]
                                as NSDictionary
                        ) { data, failure in
                            requests.finished(
                                token, data: data as Data?, failure: failure as String?)
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
                            ["operation": "cancelCommand", "token": token.uuidString]
                                as NSDictionary)
                    }
                }
            }, invalidate: invalidate)
    }

    @Test func closingReadonlyEditorDetachesExportAndReopenedControlsReceiveNativeResult()
        async throws
    {
        let runtime = ExtensionRuntime()
        let requests = Requests()
        var ownedFacades: [StudioUIFacade] = []
        var ownedEditor: VideoEditorModel?
        let fixture = StudioBackgroundExportFixture {
            ownedEditor?.close()
            for facade in ownedFacades { facade.stop() }
            await withCheckedContinuation { continuation in
                runtime.prepareToStop { continuation.resume() }
            }
            await ownedEditor?.stopAndWait()
            for facade in ownedFacades { await facade.stopAndWait() }
        }
        try await fixture.run {
            let suite = try #require(
                ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
            let started =
                runtime.execute(["operation": "start", "defaultsSuite": suite] as NSDictionary)
                as? NSDictionary
            let admitted = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
            try #require(
                started?["ok"] as? Bool == true && admitted?["running"] as? Bool == true,
                "stage=runtime admission start=\(String(describing: started)) status=\(String(describing: admitted))"
            )
            print("studio background export: runtime admitted")
            let root = try VideoEditorServiceTests.folder()
            fixture.directory = root
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
            let old = facade(runtime, requests: requests, invalidate: { invalidations += 1 })
            ownedFacades.append(old)
            let editor = VideoEditorModel(facade: old)
            ownedEditor = editor
            editor.openProject(at: source)
            try await waitUntil(
                "initial native frame",
                diagnostics: {
                    diagnostics(runtime, requests: requests, facade: old, editor: editor)
                }
            ) { editor.remoteFrame != nil || editor.errorMessage != nil }
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
            try await waitUntil(
                "native export progress",
                diagnostics: {
                    diagnostics(runtime, requests: requests, facade: old, editor: editor)
                }
            ) { (old.exporter.job?.progress ?? 0) > 0 }
            #expect(old.exporter.isExporting)
            editor.close()
            old.stop()
            try await waitUntil(
                "closed facade invalidation",
                diagnostics: {
                    "invalidations=\(invalidations) "
                        + diagnostics(runtime, requests: requests, facade: old, editor: editor)
                }
            ) { invalidations == 1 }
            let status = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
            #expect(status?["preventsQuit"] as? Bool == true)
            let reopened = facade(runtime, requests: requests)
            ownedFacades.append(reopened)
            reopened.refresh()
            try await waitUntil(
                "reopened export controls",
                diagnostics: { diagnostics(runtime, requests: requests, facade: reopened) }
            ) { reopened.state?.export != nil || reopened.failure != nil }
            #expect(reopened.failure == nil && reopened.exporter.job?.destination == output)
            let token = try #require(reopened.state?.export?.token)
            reopened.observe()
            try await waitUntil(
                "native export completion", overallLimit: .seconds(600),
                progress: {
                    max(reopened.exporter.job?.progress ?? 0, reopened.state?.export?.progress ?? 0)
                },
                diagnostics: { diagnostics(runtime, requests: requests, facade: reopened) }
            ) { reopened.exporter.job?.phase == .finished }
            let report = try #require(reopened.exporter.job?.report)
            #expect(
                report.bytes > 0 && report.frameCount == 3600 && abs(report.duration - 120) < 0.01)
            #expect(report.sha256 == (try await VideoDeliveryReport.inspect(output)).sha256)
            #expect(try Data(contentsOf: source) == original)
            #expect(reopened.exporter.job?.id == token)
            reopened.exporter.clear()
            try await waitUntil(
                "native export cleared",
                diagnostics: { diagnostics(runtime, requests: requests, facade: reopened) }
            ) {
                reopened.refresh(); return reopened.state?.export == nil
            }
            #expect(reopened.exporter.job == nil)
            reopened.stop()
            print(
                "studio background export: waiting for runtime drain "
                    + diagnostics(runtime, requests: requests, facade: reopened))
            await withCheckedContinuation { continuation in
                runtime.prepareToStop { continuation.resume() }
            }
            let disabled = runtime.execute(["operation": "status"] as NSDictionary) as? NSDictionary
            print(
                "studio background export: runtime drained status=\(String(describing: disabled))")
            #expect(
                disabled?["running"] as? Bool == false
                    && disabled?["preventsQuit"] as? Bool == false)
        }
    }
}
