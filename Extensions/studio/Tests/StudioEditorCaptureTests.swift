import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import Foundation
import PDFKit
import SwiftUI
import Testing

@testable import StudioExtension

@MainActor
@Suite(.serialized)
struct StudioEditorCaptureTests {
    private static var variants: [StudioCapture.Variant] {
        StudioCapture.directory == nil
            ? StudioCapture.Variant.all
            : StudioCapture.Variant.matrix.filter { $0.name != "regular-dark" }
    }

    private static func model() -> StudioModel {
        StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
    }

    @Test func imageAndPDFEditorsRenderAtEveryVariant() async throws {
        let folder = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("Synthetic beach.png")
        let report = folder.appendingPathComponent("Synthetic report.pdf")
        try StudioTestFiles.image(photo)
        try StudioTestFiles.pdf(
            report, pages: ["Synthetic one", "Synthetic two", "Synthetic three"])
        let studio = Self.model()
        defer { studio.shutdown() }
        let image = StudioImageEditorModel(url: photo)
        image.load()
        #expect(await StudioTestFiles.waitUntil { image.preview != nil })
        let pdf = StudioPDFEditorModel(url: report, mode: .annotate)
        pdf.load()
        #expect(await StudioTestFiles.waitUntil { pdf.session != nil })
        for variant in Self.variants {
            for panel in StudioImagePanel.allCases {
                image.panel = panel
                try await StudioCapture.render(
                    "image-\(panel)", variant: variant, expecting: ["Synthetic beach"],
                    view: StudioImageEditorView(model: studio, editor: image))
            }
            pdf.switchMode(.annotate)
            try await StudioCapture.render(
                "pdf-annotate", variant: variant, expecting: ["Synthetic report"],
                view: StudioPDFEditorView(model: studio, editor: pdf),
                prepare: StudioRenderingTests.composePages)
            pdf.switchMode(.organize)
            try await StudioCapture.render(
                "pdf-organize", variant: variant, expecting: ["Synthetic report"],
                view: StudioPDFEditorView(model: studio, editor: pdf))
            try await StudioCapture.render(
                "pdf-organize-thumbnails", variant: variant, expecting: ["Synthetic one"],
                view: StudioPDFEditorView(model: studio, editor: pdf)
                    .environment(\.automaticViewActionsEnabled, true)
                    .environment(\.windowVisible, true))
        }
    }

    @Test func compareRendersDifferencesAtEveryVariant() async throws {
        let folder = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Synthetic draft.pdf")
        let revised = folder.appendingPathComponent("Synthetic final.pdf")
        try StudioTestFiles.pdf(original, pages: ["Synthetic launch", "Synthetic budget 2400"])
        try StudioTestFiles.pdf(revised, pages: ["Synthetic launch plan", "Synthetic budget 3100"])
        let studio = Self.model()
        defer { studio.shutdown() }
        let compare = StudioCompareModel(original: original, revised: revised)
        compare.load()
        #expect(await StudioTestFiles.waitUntil { compare.report != nil })
        for variant in Self.variants {
            compare.showsVisual = false
            try await StudioCapture.render(
                "compare-text", variant: variant, expecting: ["Compare"],
                view: StudioCompareView(model: studio, compare: compare),
                prepare: StudioRenderingTests.composeCompare)
            compare.showsVisual = true
            compare.renderVisual()
            #expect(await StudioTestFiles.waitUntil { compare.visual != nil })
            try await StudioCapture.render(
                "compare-visual", variant: variant, expecting: ["Compare"],
                view: StudioCompareView(model: studio, compare: compare))
        }
    }

    @Test func runnerRunningResultAndWorkflowRenderAtEveryVariant() async throws {
        let folder = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("Synthetic part one.pdf")
        let second = folder.appendingPathComponent("Synthetic part two.pdf")
        let merged = folder.appendingPathComponent("Synthetic merged.pdf")
        try StudioTestFiles.pdf(first, pages: ["One"])
        try StudioTestFiles.pdf(second, pages: ["Two"])
        try StudioTestFiles.pdf(merged, pages: ["One", "Two"])
        for variant in Self.variants {
            let running = Self.model()
            running.open(toolID: "pdf.merge", with: [first, second])
            let runningJob = try #require(Self.job(in: running))
            runningJob.phase = .running
            runningJob.progress = 0.42
            runningJob.status = "Merging page 12 of 28"
            runningJob.startedAt = Date(timeIntervalSinceNow: -8)
            try await StudioCapture.render(
                "runner-running", variant: variant, expecting: ["Merge PDF"],
                view: StudioPage(model: running))
            runningJob.phase = .editing
            running.shutdown()

            let finished = Self.model()
            finished.open(toolID: "pdf.merge", with: [first, second])
            let finishedJob = try #require(Self.job(in: finished))
            finishedJob.result = StudioRunResult(
                toolID: "pdf.merge",
                outputs: [
                    StudioOutputFile(url: merged, kind: .pdf, bytes: 1_840_000, source: first)
                ],
                inputBytes: 2_410_000, notes: ["Merged 2 files into 2 pages."], failures: [],
                folders: [])
            finishedJob.phase = .finished
            try await StudioCapture.render(
                "runner-result", variant: variant, expecting: ["Merge PDF", "Run again"],
                view: StudioPage(model: finished))
            finished.shutdown()

            let failed = Self.model()
            failed.open(toolID: "pdf.merge", with: [first, second])
            let failedJob = try #require(Self.job(in: failed))
            failedJob.phase = .failed("The password protected file could not be opened.")
            try await StudioCapture.render(
                "runner-failed", variant: variant, expecting: ["Merge PDF"],
                view: StudioPage(model: failed))
            failed.shutdown()

            let editing = Self.model()
            let preset = try #require(StudioWorkflow.presets.dropFirst().first)
            let draft = StudioWorkflowDraft(workflow: preset)
            try await StudioCapture.render(
                "workflow-editor", variant: variant, expecting: ["Workflow"],
                view: StudioWorkflowEditor(model: editing, draft: draft))
            let empty = StudioWorkflowDraft(workflow: StudioWorkflow(name: "", steps: []))
            try await StudioCapture.render(
                "workflow-new", variant: variant, expecting: ["Workflow"],
                view: StudioWorkflowEditor(model: editing, draft: empty))
            editing.shutdown()
        }
    }

    @Test func populatedVideoTimelineRendersAtEveryVariant() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("timeline.openscreen")
        _ = try VideoEditorService.create(at: source, title: "Synthetic launch cut")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: movie.path, name: "intro"),
                .addMedia(path: movie.path, name: "demo"),
                .text(content: "Synthetic title", start: 0.2, end: 0.9),
            ]), to: source, overwrite: true)
        var project = try VideoProject.open(source)
        project.addAudio(movie, duration: 1, at: 0)
        var legacy = project.root["legacyEditor"] as? [String: Any] ?? [:]
        legacy["speedRegions"] = [["id": "speed", "startMs": 100, "endMs": 800, "speed": 2]]
        legacy["cameraFullscreenRegions"] = [["id": "camera", "startMs": 300, "endMs": 900]]
        project.root["legacyEditor"] = legacy
        try project.save(to: source)
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
        let editor = VideoEditorModel(facade: facade)
        editor.openProject(at: source)
        #expect(
            await StudioTestFiles.waitUntil {
                editor.previewReady && editor.pipeline != nil || editor.errorMessage != nil
            })
        #expect(editor.errorMessage == nil)
        #expect(editor.project?.audioTracks.count == 1)
        #expect(editor.project?.cameraFullscreenRegions.count == 1)
        editor.seek(to: 0.5)
        editor.addZoom()
        #expect(
            await StudioTestFiles.waitUntil {
                (try? VideoProject.open(source).zooms.count) == 1
            })
        for variant in Self.variants {
            try await StudioCapture.render(
                "video-timeline", variant: variant, expecting: ["Synthetic launch cut"],
                view: VideoEditorPage(model: editor, retained: true)
                    .environment(\.studioFacade, facade))
        }
        for variant in Self.variants {
            try await StudioCapture.render(
                "video-lanes", variant: variant, expecting: ["Timeline"],
                view: VideoTimeline(model: editor).environment(\.studioFacade, facade))
        }
        editor.close()
        await work.stopAndWait()
        await sessions.stopAndWait()
        resources.shutdown()
        facade.stop()
    }

    private static func job(in model: StudioModel) -> StudioJob? {
        guard case let .tool(id) = model.route else { return nil }
        return model.job(id)
    }
}
