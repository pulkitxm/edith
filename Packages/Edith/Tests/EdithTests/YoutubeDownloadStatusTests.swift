import Foundation
import Testing

@testable import EdithKit

@Suite struct YoutubeDownloadStatusTests {
    private func roundTrip(_ status: DownloadStatus) throws -> DownloadStatus {
        let data = try JSONEncoder().encode(status)
        return try JSONDecoder().decode(DownloadStatus.self, from: data)
    }

    @Test func codableRoundTripsAllCases() throws {
        let cases: [DownloadStatus] = [
            .queued,
            .resolving,
            .downloading(progress: "42.5%", videoIndex: 2, videoCount: 5),
            .done("song.m4a"),
            .error("boom"),
            .interrupted("Cancelled"),
            .interrupted(nil),
        ]
        for status in cases {
            #expect(try roundTrip(status) == status)
        }
    }

    @Test func decodingUnknownKindFallsBackToInterruptedNil() throws {
        let data = Data(#"{"kind":"exploded"}"#.utf8)
        let decoded = try JSONDecoder().decode(DownloadStatus.self, from: data)
        #expect(decoded == .interrupted(nil))
    }

    @Test func decodingDownloadingWithMissingFieldsUsesDefaults() throws {
        let data = Data(#"{"kind":"downloading"}"#.utf8)
        let decoded = try JSONDecoder().decode(DownloadStatus.self, from: data)
        #expect(decoded == .downloading(progress: "", videoIndex: 0, videoCount: 0))
    }

    @Test func parseURLsSplitsOnCommasAndNewlines() {
        let text = """
            https://youtube.com/watch?v=a, https://youtu.be/b
            https://www.youtube.com/watch?v=c
            """
        let urls = YoutubeDownloader.parseURLs(from: text)
        #expect(
            urls.map(\.absoluteString) == [
                "https://youtube.com/watch?v=a",
                "https://youtu.be/b",
                "https://www.youtube.com/watch?v=c",
            ])
    }

    @Test func parseURLsTrimsWhitespaceAndDropsEmptySegments() {
        let text = "  https://youtu.be/a  ,, \r\n , https://youtu.be/b \r\n\n"
        let urls = YoutubeDownloader.parseURLs(from: text)
        #expect(urls.map(\.absoluteString) == ["https://youtu.be/a", "https://youtu.be/b"])
    }

    @Test func parseURLsAcceptsSingleBareURL() {
        let urls = YoutubeDownloader.parseURLs(from: "https://www.youtube.com/watch?v=abc123")
        #expect(urls.map(\.absoluteString) == ["https://www.youtube.com/watch?v=abc123"])
    }

    @Test func parseURLsFiltersNonYouTubeHosts() {
        let text = "https://example.com/video, https://youtu.be/keep"
        let urls = YoutubeDownloader.parseURLs(from: text)
        #expect(urls.map(\.absoluteString) == ["https://youtu.be/keep"])
    }

    @Test func parseURLsReturnsEmptyForBlankInput() {
        #expect(YoutubeDownloader.parseURLs(from: " \n , \r\n").isEmpty)
    }

    @Test func parseProgressExtractsPlaylistPosition() {
        let line = "[download] Downloading video 2 of 5"
        let result = YoutubeDownloader.parseProgress(from: line)
        #expect(result.progress == "...")
        #expect(result.videoIndex == 2)
        #expect(result.videoCount == 5)
    }

    @Test func parseProgressExtractsPercentFromSizeLine() {
        let line = "[download]  42.5% of 3.50MiB at 1.20MiB/s ETA 00:02"
        let result = YoutubeDownloader.parseProgress(from: line)
        #expect(result.progress == "42.5%")
        #expect(result.videoIndex == 0)
        #expect(result.videoCount == 0)
    }

    @Test func parseProgressExtractsPercentWithoutSize() {
        let result = YoutubeDownloader.parseProgress(from: "[download] 100.0%")
        #expect(result.progress == "100.0%")
    }

    @Test func parseProgressMapsPostprocessingStages() {
        #expect(
            YoutubeDownloader.parseProgress(from: "[ExtractAudio] Destination: a.m4a").progress
                == "Converting...")
        #expect(
            YoutubeDownloader.parseProgress(from: "[Metadata] Adding metadata").progress
                == "Metadata...")
        #expect(
            YoutubeDownloader.parseProgress(from: "[Merger] Merging formats").progress
                == "Merging...")
    }

    @Test func parseProgressReturnsEmptyForUnrecognizedLines() {
        let result = YoutubeDownloader.parseProgress(from: "[youtube] abc: Downloading webpage")
        #expect(result.progress.isEmpty)
        #expect(result.videoIndex == 0)
        #expect(result.videoCount == 0)
    }
}
