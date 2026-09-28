import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct MediaDownloadTests {
    @Test(arguments: [
        "https://www.instagram.com/p/fixture/", "https://www.tiktok.com/@demo/video/123",
        "https://x.com/demo/status/123", "https://www.youtube.com/shorts/fixture",
        "https://www.facebook.com/reel/123", "https://www.linkedin.com/posts/demo",
        "https://www.snapchat.com/spotlight/fixture", "https://www.reddit.com/r/demo/comments/123",
        "https://www.pinterest.com/pin/123/", "https://www.flickr.com/photos/demo/123",
        "https://vimeo.com/123", "https://www.twitch.tv/videos/123",
        "https://example.com/photo.jpg",
    ])
    func acceptsSocialLinks(_ source: String) {
        #expect(YoutubeDownloader.parseURLs(from: source).map(\.absoluteString) == [source])
    }

    @Test func rejectsNonWebAndCredentialURLsAndDeduplicates() {
        let input =
            "file:///etc/hosts\nftp://example.com/a\nhttps://user:pass@example.com/a\nhttps://x.com/a\nhttps://x.com/a"
        #expect(
            YoutubeDownloader.parseURLs(from: input).map(\.absoluteString) == ["https://x.com/a"])
    }

    @Test func galleryRequestKeepsAlbumsTogetherAndFiltersImages() {
        let record = record(kind: .images)
        let request = MediaDownloadRequest.gallery(
            record, executable: URL(fileURLWithPath: "/bin/gallery-dl"))
        #expect(request.arguments.contains("--config-ignore"))
        #expect(request.arguments.contains("--filter"))
        #expect(request.arguments.contains("after:{_path}"))
        #expect(request.arguments.contains("skip:{_path}"))
        #expect(request.arguments.contains("/tmp/media-test/\(record.id.uuidString)"))
        #expect(request.arguments.suffix(2) == ["--", "https://example.com/image.jpg"])
        #expect(request.terminatesProcessGroup)
    }

    @Test func videoRequestIsIsolatedAndUsesExplicitBrowser() {
        var record = record(kind: .video)
        record.browser = .firefox
        let request = DownloadWorker.request(
            record, executable: URL(fileURLWithPath: "/bin/yt-dlp"))
        #expect(request.arguments.contains("--ignore-config"))
        #expect(request.arguments.contains("--no-overwrites"))
        #expect(request.arguments.contains("firefox"))
        #expect(request.arguments.contains("bv*+ba/b"))
        #expect(request.arguments.suffix(2) == ["--", record.url.absoluteString])
    }

    @Test func prefixCannotInjectAnOutputTemplate() {
        let template = DownloadQueue.outputTemplate(prefix: "%(title)s")
        #expect(template.contains("%%(title)s%(title).160B"))
    }

    @Test func audioExtractionPreservesExistingSourceVideo() {
        let request = DownloadWorker.request(
            record(kind: .audio), executable: URL(fileURLWithPath: "/bin/yt-dlp"))
        #expect(request.arguments.contains("--keep-video"))
        #expect(request.arguments.contains("ba/b"))
    }

    @Test func commaInsideAMediaURLIsPreserved() {
        let source = "https://example.com/image.jpg?crop=1,2,3,4"
        #expect(YoutubeDownloader.parseURLs(from: source).map(\.absoluteString) == [source])
        #expect(
            YoutubeDownloader.parseURLs(from: source + ", https://example.com/video.mp4").count == 2
        )
    }

    @Test @MainActor func browserChoiceSurvivesPersistenceAndDisplayProjection() throws {
        var original = record(kind: .post)
        original.browser = .firefox
        let decoded = try JSONDecoder().decode(
            DownloadRecord.self, from: JSONEncoder().encode(original))
        #expect(YoutubeDownloader.DownloadItem(record: decoded).record.browser == .firefox)
        let request = MediaDownloadRequest.gallery(
            decoded, executable: URL(fileURLWithPath: "/bin/gallery-dl"))
        #expect(request.arguments.contains("firefox"))
    }

    @Test @MainActor func completedItemsInvalidateQueuedRows() {
        let queued = record(kind: .images)
        var completed = queued
        completed.status = .done("photo.png")
        completed.resultPaths = ["/synthetic/photo.png"]
        #expect(
            YoutubeDownloader.DownloadItem(record: queued)
                != YoutubeDownloader.DownloadItem(record: completed))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func galleryResultsPreserveEveryFileAndFailureState(_ status: Int32) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = MediaDownloadCalls()
        let worker = DownloadWorker(
            file: folder.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/yt-dlp") },
            galleryExecutable: { URL(fileURLWithPath: "/bin/gallery-dl") }, isEnabled: { true },
            runCommand: { request, _ in
                await calls.append(request.executableURL.lastPathComponent)
                let image = folder.appendingPathComponent("first.png")
                let video = folder.appendingPathComponent("second.mp4")
                try Data([1]).write(to: image)
                try Data([2]).write(to: video)
                return CLICommandResult(
                    terminationStatus: status,
                    output: image.path + "\n" + image.path + "\n" + video.path)
            })
        try await worker.start()
        let added = try await worker.mutate(
            .enqueue(
                urls: [URL(string: "https://example.com/album")!], prefix: "", kind: .post,
                outputDirectory: folder)
        ).added[0]
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while await worker.snapshot().records.first?.isFinished != true,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await worker.snapshot()
        #expect(snapshot.records[0].canRetry == (status != 0))
        #expect(snapshot.records[0].id == added.id)
        #expect(snapshot.records[0].resultPaths?.count == 2)
        #expect(await calls.values == ["gallery-dl"])
        await worker.stop()
    }

    @Test func resultPathsExcludeFoldersAndEscapingSymlinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        var record = record(kind: .images)
        record.outputFilename = folder.appendingPathComponent("template").path
        let result = CLICommandResult(terminationStatus: 0, output: "\(folder.path)\n\(link.path)")
        #expect(DownloadWorker.resultPaths(result, record: record).isEmpty)
    }

    @Test func postFallsBackToVideoOnlyWhenGalleryProducesNoFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = MediaDownloadCalls()
        let worker = DownloadWorker(
            file: folder.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/yt-dlp") },
            galleryExecutable: { URL(fileURLWithPath: "/bin/gallery-dl") },
            isEnabled: { true },
            runCommand: { request, _ in
                await calls.append(request.executableURL.lastPathComponent)
                if request.executableURL.lastPathComponent == "gallery-dl" {
                    return CLICommandResult(terminationStatus: 1, output: "unsupported")
                }
                let output = folder.appendingPathComponent("video.mp4")
                try Data([1, 2, 3]).write(to: output)
                return CLICommandResult(terminationStatus: 0, output: output.path)
            })
        try await worker.start()
        _ = try await worker.mutate(
            .enqueue(
                urls: [URL(string: "https://example.com/post")!], prefix: "", kind: .post,
                outputDirectory: folder))
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while await worker.snapshot().finished == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await worker.snapshot().finished == 1)
        #expect(await calls.values == ["gallery-dl", "yt-dlp"])
        await worker.stop()
    }

    @Test func missingGalleryFailsWithAnActionableError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let worker = DownloadWorker(
            file: folder.appendingPathComponent("queue.json"),
            executable: { URL(fileURLWithPath: "/bin/yt-dlp") }, galleryExecutable: { nil },
            isEnabled: { true })
        try await worker.start()
        _ = try await worker.mutate(
            .enqueue(
                urls: [URL(string: "https://example.com/post")!], prefix: "", kind: .images,
                outputDirectory: folder))
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while await worker.snapshot().failed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await worker.snapshot().records.first?.detail.contains("gallery-dl") == true)
        #expect(await worker.snapshot().running == 0)
        await worker.stop()
    }

    private func record(kind: DownloadKind) -> DownloadRecord {
        DownloadRecord(
            url: URL(string: "https://example.com/image.jpg")!, status: .queued,
            outputFilename: "/tmp/media-test/%(title)s.%(ext)s", createdAt: Date(), kind: kind)
    }
}

private actor MediaDownloadCalls {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
