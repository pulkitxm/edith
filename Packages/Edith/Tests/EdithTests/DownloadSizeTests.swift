import EdithKit
import Foundation
import Testing

@Suite struct DownloadSizeTests {
    private func json(_ formats: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["formats": formats])
    }

    @Test func addsBestVideoToBestAudio() {
        let data = json([
            ["vcodec": "none", "acodec": "opus", "abr": 60, "filesize": 1_000_000],
            ["vcodec": "none", "acodec": "opus", "abr": 130, "filesize": 3_000_000],
            ["vcodec": "avc1", "acodec": "none", "height": 480, "filesize": 10_000_000],
            ["vcodec": "avc1", "acodec": "none", "height": 1080, "filesize": 40_000_000],
        ])
        let estimate = DownloadSizeParser.estimate(fromJSON: data)
        #expect(estimate?.audioBytes == 3_000_000)
        #expect(estimate?.videoBytes == 43_000_000)
        #expect(estimate?.approximate == true)
    }

    @Test func fallsBackToCombinedFormats() {
        let data = json([
            ["vcodec": "none", "acodec": "opus", "abr": 130, "filesize": 3_000_000],
            ["vcodec": "avc1", "acodec": "mp4a", "height": 720, "filesize_approx": 25_000_000],
        ])
        let estimate = DownloadSizeParser.estimate(fromJSON: data)
        #expect(estimate?.audioBytes == 3_000_000)
        #expect(estimate?.videoBytes == 25_000_000)
    }

    @Test func readsApproximateSizesWhenExactIsMissing() {
        let data = json([
            ["vcodec": "none", "acodec": "opus", "abr": 130, "filesize_approx": 2_500_000.0]
        ])
        #expect(DownloadSizeParser.estimate(fromJSON: data)?.audioBytes == 2_500_000)
    }

    @Test func returnsNilWithoutUsableSizes() {
        #expect(DownloadSizeParser.estimate(fromJSON: json([])) == nil)
        #expect(DownloadSizeParser.estimate(fromJSON: Data("nonsense".utf8)) == nil)
        let sizeless = json([["vcodec": "none", "acodec": "opus", "abr": 130]])
        #expect(DownloadSizeParser.estimate(fromJSON: sizeless) == nil)
    }

    @Test func sumsEstimatesAcrossURLs() {
        let a = DownloadEstimate(audioBytes: 1_000, videoBytes: 5_000, approximate: false)
        let b = DownloadEstimate(audioBytes: 2_000, videoBytes: nil, approximate: true)
        let total = a + b
        #expect(total.audioBytes == 3_000)
        #expect(total.videoBytes == 5_000)
        #expect(total.approximate)
    }
}
