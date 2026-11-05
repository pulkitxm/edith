import AppKit
import EdithExtensionTestSupport
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
import Vision

@testable import DownloadsExtension

@MainActor
enum DownloadsCapture {
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

    nonisolated static func recognizedText(in image: CGImage) async -> String? {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesCPUOnly = true
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                try? VNImageRequestHandler(cgImage: image).perform([request])
                finished.signal()
            }
            guard finished.wait(timeout: .now() + 30) == .success else { return nil }
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
                    .frame(width: variant.size.width, height: variant.size.height)
                    .background(DashSkin.paper(variant.dark))))
        let window = TestWindowHost.window(contentRect: CGRect(origin: .zero, size: variant.size))
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: variant.size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: directory.appendingPathComponent("downloads-\(name)-\(variant.name).png"))
        }
        window.contentView = nil
        let image = try #require(bitmap.cgImage)
        guard let text = await recognizedText(in: image) else { return }
        for label in labels {
            #expect(text.contains(label), "\(name) \(variant.name) is missing \(label)")
        }
    }
}

extension DownloadsExtensionTests {
    @MainActor @Suite(.serialized) struct CaptureTests {
        private static func record(_ path: String, _ status: DownloadStatus, kind: DownloadKind)
            -> DownloadRecord
        {
            DownloadRecord(
                url: URL(string: "https://media.example.test/\(path)")!, status: status,
                outputFilename: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                kind: kind)
        }

        private static func snapshot(
            _ records: [DownloadRecord], running: Bool = false, problem: String? = nil,
            executable: URL? = URL(fileURLWithPath: "/fixture/yt-dlp")
        ) -> DownloadWorkerSnapshot {
            DownloadWorkerSnapshot(
                records: records, logs: [:], enabled: true, running: running,
                generation: UUID(), revision: 1, problem: problem, executable: executable,
                runningCount: running ? 2 : 0)
        }

        @Test func downloadsStatesRenderCleanlyAtEveryVariant() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "downloads-capture-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let worker = DownloadWorker(
                file: root.appendingPathComponent("queue.json"),
                executable: { URL(fileURLWithPath: "/fixture/yt-dlp") })
            let states: [(String, DownloadWorkerSnapshot, [String])] = [
                ("setup", Self.snapshot([], executable: nil), ["Set up Downloads"]),
                (
                    "error",
                    Self.snapshot(
                        [], problem: "The download service stopped. Check again to restart it."),
                    ["Check again"]
                ),
                ("empty", Self.snapshot([]), ["Downloads", "Download"]),
                (
                    "working",
                    Self.snapshot(
                        [
                            Self.record(
                                "watch/fixture-one",
                                .downloading(
                                    progress: "42.0% of 18.4MiB at 3.1MiB/s", videoIndex: 1,
                                    videoCount: 3),
                                kind: .video),
                            Self.record("p/fixture-two", .resolving, kind: .post),
                            Self.record("reel/fixture-three", .queued, kind: .audio),
                        ], running: true), ["Downloads", "Update tool"]
                ),
                (
                    "populated",
                    Self.snapshot([
                        Self.record(
                            "watch/fixture-four", .done("Synthetic mountain timelapse.mp4"),
                            kind: .video),
                        Self.record(
                            "p/fixture-five",
                            .error("This post is private. Choose login cookies and retry."),
                            kind: .post),
                        Self.record(
                            "watch/fixture-six", .interrupted("Edith quit during the download"),
                            kind: .video),
                        Self.record(
                            "track/fixture-seven", .done("Synthetic podcast intro.m4a"),
                            kind: .audio),
                    ]), ["Downloads", "Update tool"]
                ),
            ]
            for variant in DownloadsCapture.Variant.all {
                for (name, snapshot, labels) in states {
                    let model = YoutubeDownloader(
                        client: DownloadsClient(worker: worker), start: false,
                        toolStatus: { .init(executable: $0, version: "fixture1") })
                    model.apply(snapshot)
                    try await DownloadsCapture.render(
                        name, variant: variant, expecting: labels,
                        view: DownloadSheet(isPage: true, downloader: model))
                    await model.shutdown()
                }
            }
            let tall: [DownloadsCapture.Variant] =
                DownloadsCapture.directory == nil
                ? []
                : [
                    DownloadsCapture.Variant(
                        name: "tall-light", size: CGSize(width: 1100, height: 1500), dark: false,
                        scale: 1),
                    DownloadsCapture.Variant(
                        name: "tall-compact-dark", size: CGSize(width: 640, height: 1700),
                        dark: true,
                        scale: 1),
                ]
            for variant in tall {
                for (name, snapshot, _) in states where name == "working" || name == "populated" {
                    let model = YoutubeDownloader(
                        client: DownloadsClient(worker: worker), start: false,
                        toolStatus: { .init(executable: $0, version: "fixture1") })
                    model.apply(snapshot)
                    try await DownloadsCapture.render(
                        name, variant: variant,
                        expecting: name == "working"
                            ? ["Finding media", "Cancel all"] : ["Retry", "Clear history"],
                        view: DownloadSheet(isPage: true, downloader: model))
                    await model.shutdown()
                }
            }
            await worker.stop()
        }

        @Test func settingsAndLogSheetsRenderAtEveryVariant() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "downloads-sheets-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let worker = DownloadWorker(
                file: root.appendingPathComponent("queue.json"),
                executable: { URL(fileURLWithPath: "/fixture/yt-dlp") })
            let model = YoutubeDownloader(
                client: DownloadsClient(worker: worker), start: false,
                toolStatus: { .init(executable: $0, version: "fixture1") })
            let item = YoutubeDownloader.DownloadItem(
                record: Self.record("watch/fixture-eight", .done("Synthetic.mp4"), kind: .video),
                logs: [
                    "[youtube] fixture-eight: Downloading webpage",
                    "[info] Available formats for fixture-eight",
                    "[download] Destination: Synthetic.mp4",
                    "[download] 100% of 18.40MiB in 00:06 at 3.07MiB/s",
                    "[Merger] Merging formats into Synthetic.mp4",
                ].joined(separator: "\n"))
            let waiting = YoutubeDownloader.DownloadItem(
                record: Self.record("p/fixture-nine", .resolving, kind: .post))
            let sheets = DownloadsCapture.Variant.all.map {
                DownloadsCapture.Variant(
                    name: $0.name, size: CGSize(width: $0.size.width, height: 560),
                    dark: $0.dark, scale: $0.scale)
            }
            for variant in sheets {
                try await DownloadsCapture.render(
                    "settings", variant: variant, expecting: ["Download tools", "ffmpeg"],
                    view: DownloadsSettings(downloader: model))
                try await DownloadsCapture.render(
                    "log", variant: variant, expecting: ["Download Log", "Merger"],
                    view: DownloadLogSheet(item: item) {})
                try await DownloadsCapture.render(
                    "log-waiting", variant: variant, expecting: variant.dark ? [] : ["Done"],
                    view: DownloadLogSheet(item: waiting) {})
            }
            await model.shutdown()
            await worker.stop()
        }
    }
}

extension DownloadsExtensionTests {
    @Suite struct ProgressTextTests {
        @Test func splitsPercentFromTransferDetail() {
            let progress = "42.0% of 18.4MiB at 3.1MiB/s"
            #expect(DownloadRowMetrics.fraction(from: progress) == 0.42)
            #expect(DownloadRowMetrics.detail(from: progress) == "18.4MiB at 3.1MiB/s")
            #expect(DownloadRowMetrics.fraction(from: "Merging formats") == nil)
            #expect(DownloadRowMetrics.detail(from: "Merging formats") == "Merging formats")
            #expect(DownloadRowMetrics.fraction(from: "100%") == 1)
        }
    }
}
