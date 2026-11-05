import AppKit
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

    nonisolated static func recognizedText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    static func render(
        _ name: String, variant: Variant, expecting labels: [String], view: some View
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
                    .transaction { $0.animation = nil }
                    .frame(width: variant.size.width, height: variant.size.height)))
        let window = TestWindowHost.window(contentRect: CGRect(origin: .zero, size: variant.size))
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: variant.size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
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
        let text = try await recognizedText(in: image)
        for label in labels {
            #expect(text.contains(label), "\(name) \(variant.name) is missing \(label)")
        }
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

@Suite struct StudioInputTextTests {
    @Test func acceptedInputsReadAsPlainLanguage() throws {
        let merge = try #require(StudioCatalog.tool("pdf.merge"))
        #expect(StudioInputText.accepted(merge) == "images or PDFs")
        let compress = try #require(StudioCatalog.tool("pdf.compress"))
        #expect(StudioInputText.accepted(compress) == "PDFs")
    }
}
