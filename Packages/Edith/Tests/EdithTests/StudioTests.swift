import AppKit
import CoreText
import EdithStudio
import Foundation
import PDFKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
enum StudioTestFiles {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-studio-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaults() -> UserDefaults {
        let name = "test.edith.studio.\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? .standard
    }

    static func pdf(_ url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw StudioError.failed("fixture")
        }
        for text in pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(box)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
            context.textPosition = CGPoint(x: 72, y: 680)
            CTLineDraw(line, context)
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
            context.fill(CGRect(x: 72, y: 420, width: 468, height: 200))
            context.endPage()
        }
        context.closePDF()
    }

    static func image(_ url: URL, width: Int = 1200, height: Int = 800) throws {
        let context = try #require(
            StudioImageOps.context(width: width, height: height, opaque: true))
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: 0.98, green: 0.62, blue: 0.4, alpha: 1),
                CGColor(srgbRed: 0.35, green: 0.3, blue: 0.75, alpha: 1),
            ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 1))
        context.fillEllipse(
            in: CGRect(x: width / 2 - 120, y: height / 2 - 20, width: 240, height: 240))
        let image = try #require(context.makeImage())
        try StudioImageIO.write(
            image, to: url, format: StudioImageFormat.of(url) ?? .png, options: .init(quality: 0.9))
    }

    static func waitUntil(
        timeout: TimeInterval = 30, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return condition()
    }
}

@MainActor
@Suite(.serialized) struct StudioModelTests {
    func model(output: URL) -> StudioModel {
        let defaults = StudioTestFiles.defaults()
        defaults.set(
            StudioDestinationMode.folder.rawValue, forKey: AppStorageKeys.Studio.destination)
        defaults.set(output.path, forKey: AppStorageKeys.Studio.folder)
        return StudioModel(defaults: defaults, loadsState: false)
    }

    @Test func addingFilesDeduplicatesExpandsFoldersAndPersists() throws {
        let folder = try StudioTestFiles.folder()
        let nested = folder.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("Report.pdf")
        let photo = nested.appendingPathComponent("Photo.png")
        try StudioTestFiles.pdf(pdf, pages: ["One"])
        try StudioTestFiles.image(photo)
        let defaults = StudioTestFiles.defaults()
        let model = StudioModel(defaults: defaults, loadsState: false)
        model.add([pdf, nested])
        model.add([pdf])
        #expect(model.files.count == 2)
        #expect(Set(model.kindsPresent) == [.pdf, .image])
        model.kindFilter = .image
        #expect(model.visibleFiles.map(\.name) == ["Photo.png"])
        let restored = StudioModel(defaults: defaults)
        #expect(
            Set(restored.files.map(\.url)) == [pdf.standardizedFileURL, photo.standardizedFileURL])
        model.selectAll()
        #expect(model.selection == [photo.standardizedFileURL])
        model.remove([photo.standardizedFileURL])
        #expect(model.files.count == 1)
        #expect(model.selection.isEmpty)
    }

    @Test func quickActionsRouteToTheRightEditorsAndRunners() throws {
        let folder = try StudioTestFiles.folder()
        let model = model(output: folder)
        let pdf = folder.appendingPathComponent("a.pdf")
        let other = folder.appendingPathComponent("b.pdf")
        let photo = folder.appendingPathComponent("c.jpg")
        let clip = folder.appendingPathComponent("d.mov")
        try StudioTestFiles.pdf(pdf, pages: ["A"])
        try StudioTestFiles.pdf(other, pages: ["B"])
        try StudioTestFiles.image(photo)
        model.quick(.edit, for: photo)
        #expect(model.route == .imageEditor(photo))
        model.quick(.edit, for: pdf)
        #expect(model.route == .pdfEditor(pdf, .annotate))
        model.quick(.edit, for: clip)
        #expect(model.route == .videoEditor([clip], project: nil))
        model.quick(.compress, for: pdf)
        guard case let .tool(id) = model.route, let job = model.job(id) else {
            Issue.record("compress should open a runner")
            return
        }
        #expect(job.tool.id == "pdf.compress")
        #expect(job.inputs == [pdf])
        model.open(toolID: "pdf.compare", with: [pdf, other])
        #expect(model.route == .compare(pdf, other))
        model.open(toolID: "pdf.organize", with: [pdf])
        #expect(model.route == .pdfEditor(pdf, .organize))
        model.goHome()
        #expect(model.route == .home)
    }

    @Test func jobsFilterInputsAndRunEndToEnd() async throws {
        let folder = try StudioTestFiles.folder()
        let output = folder.appendingPathComponent("out", isDirectory: true)
        let model = model(output: output)
        let first = folder.appendingPathComponent("first.pdf")
        let second = folder.appendingPathComponent("second.pdf")
        let photo = folder.appendingPathComponent("photo.png")
        try StudioTestFiles.pdf(first, pages: ["One", "Two"])
        try StudioTestFiles.pdf(second, pages: ["Three"])
        try StudioTestFiles.image(photo)
        model.environment = StudioEngineLocator.detect()
        model.open(toolID: "pdf.merge", with: [first, photo, second])
        guard case let .tool(id) = model.route, let job = model.job(id) else {
            Issue.record("merge should open a runner")
            return
        }
        #expect(job.inputs == [first, photo, second])
        job.move(second, by: -2)
        #expect(job.inputs.first == second)
        #expect(job.validationMessage == nil)
        model.run(job)
        #expect(job.isRunning)
        #expect(await StudioTestFiles.waitUntil { !job.isRunning })
        #expect(job.phase == .finished)
        #expect(job.units == 1)
        let result = try #require(job.result)
        let mergedURL = try #require(result.outputs.first).url
        let merged = try #require(PDFDocument(url: mergedURL))
        #expect(merged.pageCount == 4)
        #expect(merged.page(at: 0)?.string?.contains("Three") == true)
        #expect(
            result.outputs.first?.url.deletingLastPathComponent().standardizedFileURL
                == output.standardizedFileURL)
        #expect(model.recent.first?.toolID == "pdf.merge")
        let next = StudioResultText.continuations(for: [mergedURL], after: job.tool)
        #expect(next.contains { $0.id == "pdf.compress" })
        #expect(!next.contains { $0.id == "pdf.merge" })

        let failing = StudioJob(
            tool: try #require(StudioCatalog.tool("pdf.protect")), inputs: [first])
        #expect(failing.validationMessage != nil)
        let rejected = StudioJob(
            tool: try #require(StudioCatalog.tool("pdf.compress")), inputs: [photo])
        #expect(rejected.inputs.isEmpty)
    }

    @Test func cancellingAJobStopsIt() async throws {
        let folder = try StudioTestFiles.folder()
        let model = model(output: folder)
        let pdf = folder.appendingPathComponent("long.pdf")
        try StudioTestFiles.pdf(pdf, pages: Array(repeating: "Scan", count: 40))
        let job = StudioJob(
            tool: try #require(StudioCatalog.tool("pdf.ocr")), inputs: [pdf],
            settings: StudioSettings(["skipText": .bool(false)]))
        model.jobs.insert(job, at: 0)
        model.run(job)
        try await Task.sleep(for: .milliseconds(120))
        job.cancel()
        #expect(!job.isRunning)
        if case .failed = job.phase {
        } else {
            Issue.record("a cancelled job reports it was cancelled")
        }
    }

    @Test func pasteAndScanImportsLandInTheInbox() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("studio-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPage(mediaBox: &box)
        context.endPage()
        context.closePDF()
        pasteboard.setData(data as Data, forType: .pdf)
        let scanned = try StudioScanImport.save(pasteboard)
        #expect(scanned.count == 1)
        #expect(scanned.first?.pathExtension == "pdf")
        #expect(scanned.first?.path.hasPrefix(StudioLibraryStore.inbox.path) == true)
        let pasted = try StudioLibraryStore.pasteboardFiles(pasteboard)
        #expect(pasted.first?.pathExtension == "pdf")
        let view = StudioScanHostView()
        #expect(
            view.validRequestor(forSendType: nil, returnType: .pdf) as? StudioScanHostView === view)
        var imported: [URL] = []
        view.onImport = { imported = $0 }
        #expect(view.readSelection(from: pasteboard))
        #expect(imported.count == 1)
    }

    @Test func destinationFollowsTheSetting() throws {
        let defaults = StudioTestFiles.defaults()
        let model = StudioModel(defaults: defaults, loadsState: false)
        #expect(model.destination == .nextToOriginal)
        defaults.set("downloads", forKey: AppStorageKeys.Studio.destination)
        guard case let .folder(url) = model.destination else {
            Issue.record("downloads resolves to a folder")
            return
        }
        #expect(url.lastPathComponent == "Downloads")
        defaults.set("folder", forKey: AppStorageKeys.Studio.destination)
        #expect(model.destination == .nextToOriginal)
        defaults.set("/tmp/studio-out", forKey: AppStorageKeys.Studio.folder)
        #expect(
            model.destination == .folder(URL(fileURLWithPath: "/tmp/studio-out", isDirectory: true))
        )
    }

    @Test func workflowsAreEditedSavedAndRunThroughTheRunner() async throws {
        let folder = try StudioTestFiles.folder()
        let output = folder.appendingPathComponent("out", isDirectory: true)
        let model = model(output: output)
        model.environment = StudioEngineLocator.detect()
        model.editWorkflow(nil)
        let draft = try #require(model.editingWorkflow)
        model.saveWorkflow(draft)
        #expect(draft.failure != nil)
        draft.name = "Merge then number"
        #expect(draft.candidates.contains { $0.id == "pdf.merge" })
        draft.append(try #require(StudioCatalog.tool("pdf.merge")))
        #expect(draft.candidates.contains { $0.id == "pdf.page-numbers" })
        #expect(!draft.candidates.contains { $0.id == "image.resize" })
        draft.append(try #require(StudioCatalog.tool("pdf.page-numbers")))
        draft.steps[1].set("format", .text("{n} / {total}"))
        model.saveWorkflow(draft)
        #expect(model.editingWorkflow == nil)
        let saved = try #require(model.workflows.first { $0.name == "Merge then number" })
        #expect(saved.steps.count == 2)
        let reloaded = StudioWorkflowStore.load()
        #expect(reloaded.contains { $0.id == saved.id })
        let a = folder.appendingPathComponent("a.pdf")
        let b = folder.appendingPathComponent("b.pdf")
        try StudioTestFiles.pdf(a, pages: ["A"])
        try StudioTestFiles.pdf(b, pages: ["B"])
        model.runWorkflow(saved, with: [a, b])
        guard case let .tool(id) = model.route, let job = model.job(id) else {
            Issue.record("running a workflow opens the runner")
            return
        }
        model.run(job)
        #expect(await StudioTestFiles.waitUntil { !job.isRunning })
        let url = try #require(job.result?.outputs.first?.url)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 1)?.string?.contains("2 / 2") == true)
        model.deleteWorkflow(saved)
        #expect(!StudioWorkflowStore.load().contains { $0.id == saved.id })
    }

    @Test func extensionIsRegisteredWithItsEnginesAndPage() {
        let entry = ExtensionRegistry.entries.first { $0.id == "studio" }
        #expect(entry?.defaultsKey == AppStorageKeys.Tabs.studioEnabled)
        #expect(entry?.optionalToolIDs == ["ffmpeg", "qpdf"])
        #expect(ToolProvisioning.spec(id: "qpdf") != nil)
        #expect(MainDestination.studio.rawValue == "studio")
        #expect(
            ConfigCatalog.definition(for: AppStorageKeys.Studio.destination)?.allowed == [
                "original", "downloads", "folder",
            ])
    }
}

@MainActor
@Suite(.serialized) struct StudioEditorModelTests {
    @Test func pdfEditorAnnotatesUndoesAndSavesACopy() async throws {
        let folder = try StudioTestFiles.folder()
        let source = folder.appendingPathComponent("Contract.pdf")
        try StudioTestFiles.pdf(source, pages: ["Page one", "Page two"])
        let studio = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let editor = StudioPDFEditorModel(url: source, mode: .annotate)
        editor.load()
        #expect(editor.pageCount == 2)
        editor.tool = .rectangle
        editor.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180), page: 0)
        editor.tool = .text
        editor.pendingText = "Approved"
        editor.click(at: CGPoint(x: 80, y: 700), page: 1)
        #expect(editor.selected?.contents == "Approved")
        #expect(editor.session?.page(0)?.annotations.count == 1)
        editor.undo()
        #expect(editor.session?.page(1)?.annotations.isEmpty == true)
        editor.redo()
        #expect(editor.session?.page(1)?.annotations.count == 1)
        editor.switchMode(.redact)
        editor.drag(from: CGPoint(x: 70, y: 670), to: CGPoint(x: 300, y: 720), page: 0)
        #expect(editor.session?.redactionCount == 1)
        editor.switchMode(.organize)
        editor.rotate([1], by: 90)
        #expect(editor.session?.page(1)?.rotation == 90)
        editor.save(studio: studio)
        #expect(await StudioTestFiles.waitUntil { !editor.isSaving })
        let saved = try #require(editor.lastSaved)
        #expect(saved.lastPathComponent == "Contract-organized.pdf")
        let document = try #require(PDFDocument(url: saved))
        #expect(document.pageCount == 2)
        let firstPageText = document.page(at: 0)?.string ?? ""
        #expect(firstPageText.contains("Page one") == false)
        #expect(document.page(at: 1)?.rotation == 90)
        #expect(studio.files.contains { $0.url == saved })
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!editor.isDirty)
        editor.rotate([0], by: 90)
        #expect(editor.isDirty)
    }

    @Test func pdfEditorFormsSignaturesAndCrop() throws {
        let folder = try StudioTestFiles.folder()
        let source = folder.appendingPathComponent("Form.pdf")
        try StudioTestFiles.pdf(source, pages: ["Name ________"])
        let editor = StudioPDFEditorModel(url: source, mode: .forms)
        editor.load()
        #expect(editor.tool == .fill)
        editor.tool = .textField
        editor.drag(from: CGPoint(x: 100, y: 600), to: CGPoint(x: 300, y: 624), page: 0)
        editor.tool = .dropdown
        editor.dropdownOptions = "Red, Green"
        editor.drag(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 260, y: 522), page: 0)
        let widgets = editor.session?.page(0)?.annotations.filter { $0.type == "Widget" } ?? []
        #expect(widgets.count == 2)
        #expect(widgets.contains { $0.choices == ["Red", "Green"] })
        editor.switchMode(.sign)
        let signature = try #require(
            StudioSignature.typed("A. Tester", font: "Snell Roundhand", color: .black))
        editor.pendingImage = signature
        editor.tool = .signature
        editor.click(at: CGPoint(x: 300, y: 200), page: 0)
        #expect(editor.session?.placements.count == 1)
        editor.switchMode(.crop)
        editor.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 400, y: 500), page: 0)
        #expect(editor.cropRect != nil)
        editor.applyCrop(toAllPages: true)
        #expect(editor.session?.page(0)?.bounds(for: .cropBox).width == 350)
    }

    @Test func imageEditorEditsUndoesAndExports() async throws {
        let folder = try StudioTestFiles.folder()
        let source = folder.appendingPathComponent("Sunset.jpg")
        try StudioTestFiles.image(source)
        let studio = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        let editor = StudioImageEditorModel(url: source)
        editor.load()
        #expect(await StudioTestFiles.waitUntil { editor.preview != nil })
        editor.edit { $0.adjustments.contrast = 0.3 }
        editor.edit { $0.filter = .mono }
        editor.addText(at: CGPoint(x: 0.5, y: 0.2), text: "Golden hour")
        #expect(editor.document.layers.count == 1)
        editor.addStroke([
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.6, y: 0.2),
        ])
        editor.addRedaction(from: CGPoint(x: 0.6, y: 0.6), to: CGPoint(x: 0.9, y: 0.9))
        #expect(editor.document.layers.count == 3)
        editor.undo()
        #expect(editor.document.layers.count == 2)
        editor.edit { $0.rotateClockwise() }
        editor.edit { $0.export.maxDimension = 600 }
        editor.save(studio: studio)
        #expect(await StudioTestFiles.waitUntil { !editor.isSaving })
        let saved = try #require(editor.lastSaved)
        #expect(saved.lastPathComponent == "Sunset-edited.jpg")
        #expect(!editor.hasUnsavedChanges)
        editor.edit { $0.filter = .noir }
        #expect(editor.hasUnsavedChanges)
        let info = try #require(StudioImageIO.info(saved))
        #expect(max(info.width, info.height) == 600)
        #expect(info.height > info.width)
    }
}

@MainActor
@Suite(.serialized) struct StudioRenderingTests {
    static var evidence: URL? {
        ProcessInfo.processInfo.environment["EDITH_STUDIO_EVIDENCE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    func render<Content: View>(
        _ view: Content, name: String, size: CGSize = CGSize(width: 1320, height: 860),
        prepare: ((NSView) -> Void)? = nil
    ) throws {
        let host = NSHostingView(
            rootView: view.environment(\.colorScheme, .dark).transaction { $0.animation = nil })
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<6 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        }
        prepare?(host)
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        guard let folder = Self.evidence else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func library() throws -> (StudioModel, [URL]) {
        let folder = try StudioTestFiles.folder()
        let names = [
            "Quarterly report.pdf", "Offer letter.pdf", "Beach day.jpg", "Team offsite.png",
        ]
        var urls: [URL] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            if name.hasSuffix(".pdf") {
                try StudioTestFiles.pdf(
                    url, pages: [name.replacingOccurrences(of: ".pdf", with: ""), "Details"])
            } else {
                try StudioTestFiles.image(url)
            }
            urls.append(url)
        }
        let model = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        model.environment = StudioEngineLocator.detect()
        model.add(urls)
        model.notice = nil
        return (model, urls)
    }

    func prewarm(_ urls: [URL]) async {
        for url in urls {
            for side in [48.0, 64, 160, 220, 320] {
                _ = await StudioThumbnails.shared.thumbnail(for: url, side: side)
            }
        }
    }

    @Test func homeTabsRender() async throws {
        let empty = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        try render(
            StudioPage(model: empty).environment(\.automaticViewActionsEnabled, false),
            name: "studio-empty")
        let (model, urls) = try library()
        await prewarm(urls)
        for url in urls {
            await model.loadFacts(for: url)
            #expect(StudioThumbnails.shared.cached(url, side: 220) != nil)
        }
        model.selection = [urls[0], urls[1]]
        try render(
            StudioPage(model: model).environment(\.automaticViewActionsEnabled, false),
            name: "studio-files")
        model.selection = []
        model.workflows = StudioWorkflow.presets
        model.tab = .tools
        try render(
            StudioPage(model: model).environment(\.automaticViewActionsEnabled, false),
            name: "studio-tools",
            size: CGSize(width: 1320, height: 1500))
        model.tab = .projects
        try render(
            StudioPage(model: model).environment(\.automaticViewActionsEnabled, false),
            name: "studio-projects")
    }

    @Test func runnerAndResultRender() async throws {
        let (model, urls) = try library()
        await prewarm(urls)
        for url in urls { await model.loadFacts(for: url) }
        model.open(toolID: "pdf.merge", with: [urls[0], urls[1]])
        try render(
            StudioPage(model: model).environment(\.automaticViewActionsEnabled, false),
            name: "studio-runner")
        guard case let .tool(id) = model.route, let job = model.job(id) else { return }
        model.run(job)
        #expect(await StudioTestFiles.waitUntil { !job.isRunning })
        await prewarm(job.result?.outputs.map(\.url) ?? [])
        try render(
            StudioPage(model: model).environment(\.automaticViewActionsEnabled, false),
            name: "studio-result")
        model.open(toolID: "image.watermark", with: [urls[2]])
        guard case let .tool(watermarkID) = model.route, let watermark = model.job(watermarkID)
        else { return }
        watermark.set("text", .text("Summer 2026"))
        watermark.set("position", .text("bottom-right"))
        watermark.set("rotation", .number(0))
        watermark.set("opacity", .number(0.85))
        watermark.set("color", .text("#FFFFFF"))
        watermark.preview.refresh(
            tool: watermark.tool, input: urls[2], settings: watermark.settings,
            environment: model.environment)
        #expect(await StudioTestFiles.waitUntil { watermark.preview.after != nil })
        #expect(watermark.preview.failure == nil)
        try render(
            StudioPage(model: model).environment(\.automaticViewActionsEnabled, false),
            name: "studio-watermark")
    }

    static func composePages(in root: NSView) {
        for canvas in Self.views(of: StudioPDFCanvasView.self, in: root) {
            (canvas.superview as? StudioPDFCanvasContainer)?.setThumbnailsVisible(false)
            canvas.superview?.layoutSubtreeIfNeeded()
            canvas.autoScales = false
            if let page = canvas.document?.page(at: 0) {
                let size = StudioPDF.displaySize(page)
                canvas.scaleFactor =
                    min(canvas.bounds.width / size.width, canvas.bounds.height / size.height) * 0.94
            }
            canvas.layoutDocumentView()
            canvas.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            canvas.layoutDocumentView()
            for page in canvas.visiblePages {
                let rect = canvas.convert(page.bounds(for: canvas.displayBox), from: page)
                guard let image = try? StudioPDF.render(page, dpi: 144) else { continue }
                let view = NSImageView(frame: canvas.convert(rect, to: canvas.superview))
                view.image = NSImage(cgImage: image, size: rect.size)
                view.imageScaling = .scaleAxesIndependently
                canvas.superview?.addSubview(view)
            }
            canvas.overlay.removeFromSuperview()
            canvas.superview?.addSubview(canvas.overlay)
            canvas.overlay.frame = canvas.frame
            canvas.overlay.needsDisplay = true
        }
    }

    static func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for child in root.subviews { found += views(of: type, in: child) }
        return found
    }

    @Test func editorsRender() async throws {
        let (model, urls) = try library()
        let pdf = StudioPDFEditorModel(url: urls[0], mode: .annotate)
        pdf.load()
        pdf.tool = .rectangle
        pdf.drag(from: CGPoint(x: 90, y: 400), to: CGPoint(x: 330, y: 470), page: 0)
        pdf.tool = .arrow
        pdf.drag(from: CGPoint(x: 420, y: 300), to: CGPoint(x: 350, y: 420), page: 0)
        pdf.tool = .text
        pdf.pendingText = "Numbers confirmed with finance"
        pdf.click(at: CGPoint(x: 360, y: 300), page: 0)
        if let signature = StudioSignature.typed(
            "Alex Morgan", font: "Snell Roundhand",
            color: StudioColor(red: 0.07, green: 0.14, blue: 0.47))
        {
            pdf.pendingImage = signature
            pdf.tool = .signature
            pdf.click(at: CGPoint(x: 420, y: 150), page: 0)
        }
        pdf.tool = .select
        try render(
            StudioPDFEditorView(model: model, editor: pdf).environment(
                \.automaticViewActionsEnabled, false),
            name: "studio-pdf-editor", prepare: Self.composePages)
        pdf.switchMode(.organize)
        pdf.pageSelection = [1]
        try render(
            StudioPDFEditorView(model: model, editor: pdf).environment(
                \.automaticViewActionsEnabled, false),
            name: "studio-pdf-organize")
        let image = StudioImageEditorModel(url: urls[2])
        image.load()
        #expect(await StudioTestFiles.waitUntil { image.preview != nil })
        image.edit { $0.filter = .vivid }
        image.addText(at: CGPoint(x: 0.5, y: 0.18), text: "Beach day")
        image.addSticker("🌴")
        image.panel = .text
        #expect(await StudioTestFiles.waitUntil { !image.isRendering })
        try render(
            StudioImageEditorView(model: model, editor: image).environment(
                \.automaticViewActionsEnabled, false),
            name: "studio-image-editor")
        let compare = StudioCompareModel(original: urls[0], revised: urls[1])
        compare.load()
        #expect(await StudioTestFiles.waitUntil { compare.report != nil })
        #expect(compare.report?.isIdentical == false)
        try render(
            StudioCompareView(model: model, compare: compare).environment(
                \.automaticViewActionsEnabled, false),
            name: "studio-compare", prepare: Self.composeCompare)
    }

    static func composeCompare(in root: NSView) {
        for view in Self.views(of: PDFView.self, in: root) {
            view.layoutDocumentView()
            for page in view.visiblePages {
                let rect = view.convert(page.bounds(for: view.displayBox), from: page)
                guard let image = try? StudioPDF.render(page, dpi: 110) else { continue }
                let overlay = NSImageView(frame: view.convert(rect, to: view.superview))
                overlay.image = NSImage(cgImage: image, size: rect.size)
                overlay.imageScaling = .scaleAxesIndependently
                view.superview?.addSubview(overlay)
            }
        }
    }
}
