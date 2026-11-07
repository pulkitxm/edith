import AppKit
import EdithExtensionTestSupport
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import Foundation
import SwiftUI
import Testing
import Vision

@testable import StudioExtension

@MainActor
enum StudioCapture {
    struct Variant {
        let name: String
        let size: CGSize
        let dark: Bool
        let scale: Double

        static let matrix = [
            Variant(
                name: "regular-light", size: CGSize(width: 1100, height: 760), dark: false, scale: 1
            ),
            Variant(
                name: "regular-dark", size: CGSize(width: 1100, height: 760), dark: true, scale: 1),
            Variant(
                name: "compact-light", size: CGSize(width: 640, height: 700), dark: false, scale: 1),
            Variant(
                name: "compact-dark", size: CGSize(width: 640, height: 700), dark: true, scale: 1),
            Variant(
                name: "zoom-light", size: CGSize(width: 1100, height: 760), dark: false, scale: 1.6),
            Variant(
                name: "wide-light", size: CGSize(width: 1600, height: 1000), dark: false, scale: 1),
        ]

        static var all: [Variant] {
            ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] == nil
                ? matrix.filter { $0.name == "compact-light" } : matrix
        }
    }

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    nonisolated static func upscaled(_ image: CGImage, by factor: Int = 2) -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: image.width * factor, height: image.height * factor,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
        return context.makeImage() ?? image
    }

    nonisolated static func recognizedText(in source: CGImage) async -> String? {
        let image = upscaled(source)
        return await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.usesCPUOnly = true
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                try? VNImageRequestHandler(cgImage: image).perform([request])
                finished.signal()
            }
            guard finished.wait(timeout: .now() + 30) == .success else { return nil }
            return (request.results ?? []).flatMap { $0.topCandidates(3).map(\.string) }
                .joined(separator: "\n")
        }.value
    }

    static func render(
        _ name: String, variant: Variant, expecting labels: [String], view: some View,
        prepare: ((NSView) -> Void)? = nil
    ) async throws {
        let previous = UIScale.current
        UIScale.apply(variant.scale)
        defer { UIScale.apply(previous) }
        let host = NSHostingView(
            rootView: AnyView(
                view
                    .environment(\.compactLayout, variant.size.width / variant.scale < 720)
                    .environment(\.colorScheme, variant.dark ? .dark : .light)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.windowVisible, false)
                    .environment(\.controlActiveState, .key)
                    .controlSize(UIScale.controlSize)
                    .themedControls()
                    .transaction { $0.animation = nil }
                    .frame(width: variant.size.width, height: variant.size.height)
                    .background(DashSkin.paper(variant.dark))))
        let window = TestWindowHost.window(contentRect: CGRect(origin: .zero, size: variant.size))
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: variant.size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        prepare?(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: directory.appendingPathComponent("studio-\(name)-\(variant.name).png"))
        }
        window.contentView = nil
        let image = try #require(bitmap.cgImage)
        guard let text = await recognizedText(in: image) else { return }
        for label in labels {
            #expect(
                recognizes(label, in: text), "\(name) \(variant.name) is missing \(label)")
        }
    }

    private static func recognizes(_ label: String, in text: String) -> Bool {
        if text.contains(label) { return true }
        let target = Array(label.lowercased())
        let allowed = max(1, target.count / 8)
        for line in text.lowercased().split(separator: "\n") {
            let characters = Array(line)
            guard characters.count >= target.count else { continue }
            for start in 0...(characters.count - target.count) {
                let window = characters[start..<(start + target.count)]
                if zip(window, target).filter({ $0 != $1 }).count <= allowed { return true }
            }
        }
        return false
    }
}

@MainActor
@Suite(.serialized)
struct StudioCaptureTests {
    private static func model(tab: StudioTab) -> StudioModel {
        let facade = StudioUIFacade { _, _ in throw ExtensionEngineError.unavailable }
        let model = StudioModel(
            defaults: StudioTestFiles.defaults(), loadsState: false, facade: facade)
        model.tab = tab
        return model
    }

    @Test func studioTabsRenderCleanlyAtEveryVariant() async throws {
        let folder = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("Synthetic beach.png")
        let poster = folder.appendingPathComponent("Synthetic poster.jpg")
        let report = folder.appendingPathComponent("Synthetic quarterly report.pdf")
        let notes = folder.appendingPathComponent("Synthetic notes.pdf")
        try StudioTestFiles.image(photo)
        try StudioTestFiles.image(poster, width: 800, height: 1200)
        try StudioTestFiles.pdf(report, pages: ["Synthetic page one", "Synthetic page two"])
        try StudioTestFiles.pdf(notes, pages: ["Synthetic notes"])
        let files = [photo, poster, report, notes].map { StudioFileItem(url: $0) }
        let projectURL = folder.appendingPathComponent("Synthetic launch video.edithvideo")
        for variant in StudioCapture.Variant.all {
            let filesEmpty = Self.model(tab: .files)
            try await StudioCapture.render(
                "files-empty", variant: variant, expecting: ["Studio", "Drop a file here"],
                view: StudioPage(model: filesEmpty).environment(\.studioFacade, filesEmpty.facade))
            filesEmpty.shutdown()

            let filesPopulated = Self.model(tab: .files)
            filesPopulated.files = files
            filesPopulated.selection = [photo, poster]
            try await StudioCapture.render(
                "files-populated", variant: variant, expecting: ["Studio", "2 selected"],
                view: StudioPage(model: filesPopulated)
                    .environment(\.studioFacade, filesPopulated.facade))
            filesPopulated.shutdown()

            let tools = Self.model(tab: .tools)
            try await StudioCapture.render(
                "tools", variant: variant, expecting: ["Studio", "Tools"],
                view: StudioPage(model: tools).environment(\.studioFacade, tools.facade))
            tools.shutdown()

            let toolsNoMatch = Self.model(tab: .tools)
            toolsNoMatch.toolQuery = "zzzz"
            try await StudioCapture.render(
                "tools-no-match", variant: variant, expecting: ["No tools match"],
                view: StudioPage(model: toolsNoMatch)
                    .environment(\.studioFacade, toolsNoMatch.facade))
            toolsNoMatch.shutdown()

            let projectsEmpty = Self.model(tab: .projects)
            try await StudioCapture.render(
                "projects-empty", variant: variant, expecting: ["Studio", "Video projects"],
                view: StudioPage(model: projectsEmpty)
                    .environment(\.studioFacade, projectsEmpty.facade))
            projectsEmpty.shutdown()

            let projects = Self.model(tab: .projects)
            projects.videoProjects = [
                VideoProject.Listing(
                    url: projectURL, title: "Synthetic launch video", isOpenScreenLibrary: false,
                    previewURL: nil, modified: Date(timeIntervalSince1970: 1_790_000_000)),
                VideoProject.Listing(
                    url: folder.appendingPathComponent("Synthetic tutorial.openscreen"),
                    title: "Synthetic tutorial", isOpenScreenLibrary: true, previewURL: nil,
                    modified: Date(timeIntervalSince1970: 1_789_000_000)),
            ]
            projects.recent = [
                StudioRecentRun(
                    id: UUID(), toolID: "image.compress", title: "Compress images",
                    outputs: [photo], date: Date(timeIntervalSince1970: 1_790_000_000)),
                StudioRecentRun(
                    id: UUID(), toolID: "pdf.merge", title: "Merge PDFs",
                    outputs: [report, notes], date: Date(timeIntervalSince1970: 1_789_900_000)),
            ]
            try await StudioCapture.render(
                "projects-populated", variant: variant, expecting: ["Synthetic launch video"],
                view: StudioPage(model: projects).environment(\.studioFacade, projects.facade))
            projects.shutdown()

            let runnerEmpty = Self.model(tab: .tools)
            runnerEmpty.open(try #require(StudioCatalog.tool("pdf.merge")), with: [])
            try await StudioCapture.render(
                "runner-empty", variant: variant, expecting: ["Merge PDF"],
                view: StudioPage(model: runnerEmpty).environment(\.studioFacade, runnerEmpty.facade)
            )
            runnerEmpty.shutdown()

            let runner = Self.model(tab: .tools)
            runner.open(try #require(StudioCatalog.tool("pdf.merge")), with: [report, notes])
            try await StudioCapture.render(
                "runner-ready", variant: variant, expecting: ["Merge PDF"],
                view: StudioPage(model: runner).environment(\.studioFacade, runner.facade))
            runner.shutdown()

            let videoFacade = StudioUIFacade { _, _ in throw ExtensionEngineError.unavailable }
            let video = VideoEditorModel(facade: videoFacade)
            try await StudioCapture.render(
                "video-empty", variant: variant, expecting: ["Make a video your own"],
                view: VideoEditorPage(model: video, retained: true)
                    .environment(\.studioFacade, videoFacade))
            video.recentProjects = projects.videoProjects
            try await StudioCapture.render(
                "video-recent", variant: variant, expecting: ["Make a video your own"],
                view: VideoEditorPage(model: video, retained: true)
                    .environment(\.studioFacade, videoFacade))
            video.close()
            videoFacade.stop()
        }
    }
}

@Suite struct StudioTileRowsTests {
    private func sizes(_ count: Int, fit: Int) -> [Int] {
        StudioTileRows.rows(
            count: count, available: CGFloat(fit) * 100, minimum: 100, spacing: 0
        ).map(\.count)
    }

    @Test func tilesFillEveryRowWithoutStrandingOne() {
        #expect(sizes(2, fit: 6) == [2])
        #expect(sizes(1, fit: 6) == [1])
        #expect(sizes(12, fit: 5) == [4, 4, 4])
        #expect(sizes(7, fit: 6) == [4, 3])
        #expect(sizes(13, fit: 6) == [5, 4, 4])
        #expect(sizes(0, fit: 6).isEmpty)
    }

    @Test func compactLimitStacksTiles() {
        let rows = StudioTileRows.rows(
            count: 3, available: 600, minimum: 100, spacing: 0, maximumColumns: 1)
        #expect(rows.map(\.count) == [1, 1, 1])
    }
}

@Suite struct StudioInputTextTests {
    @Test func acceptedInputsReadAsPlainLanguage() throws {
        let merge = try #require(StudioCatalog.tool("pdf.merge"))
        #expect(StudioInputText.accepted(merge) == "images or PDFs")
        let compress = try #require(StudioCatalog.tool("pdf.compress"))
        #expect(StudioInputText.accepted(compress) == "PDFs")
    }
}
