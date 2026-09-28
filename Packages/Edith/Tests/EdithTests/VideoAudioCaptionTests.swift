import AVFoundation
import AppKit
import CoreImage
import Foundation
import Testing
@testable import Edith

@Suite struct VideoAudioCaptionTests {
    @Test func captionImageIncludesItsBackgroundPlate() throws {
        var project = VideoProject.create()
        project.addText("I", startMs: 0, endMs: 1000)
        let id = try #require(project.annotations.first?.id)
        project.setAnnotationStyle(id, key: "backgroundColor", value: "#FF0000")
        let image = try #require(
            VideoCaptionImage.make(
                project.annotations[0], time: 300, size: CGSize(width: 64, height: 64)))
        let bitmap = NSBitmapImageRep(
            cgImage: try #require(CIContext().createCGImage(image, from: image.extent)))
        let pixel = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(pixel.redComponent > 0.8)
        #expect(pixel.greenComponent < 0.2)
    }
    @Test func subtitlesRoundTripAcrossBothFormats() {
        let cues = [
            VideoSubtitle(start: 1.125, end: 2.75, text: "Hello\nworld"),
            VideoSubtitle(start: 3601.5, end: 3603, text: "Final cue"),
        ]
        for vtt in [false, true] {
            #expect(VideoSubtitle.parse(VideoSubtitle.encode(cues, vtt: vtt)) == cues)
        }
        let web = "WEBVTT\n\nintro\n00:01.000 --> 00:02.000 align:start\n<b>Welcome</b>\n"
        #expect(VideoSubtitle.parse(web) == [VideoSubtitle(start: 1, end: 2, text: "Welcome")])
        #expect(VideoSubtitle.parse("1\n00:02,000 --> 00:01,000\nInvalid\n").isEmpty)
    }

    @Test func splitAndMergeCaptionsPreserveAnchors() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/video.mp4"), duration: 10, width: 640, height: 360)
        project.addText("One two three four", startMs: 1000, endMs: 5000)
        let id = try #require(project.annotations.first?.id)
        project.splitCaption(id, at: 3000)
        #expect(project.annotations.map(\.text) == ["One two", "three four"])
        #expect(project.annotations[0].endMs == 3000)
        #expect(project.annotations[1].startMs == 3000)
        #expect(
            project.annotations.allSatisfy { $0.raw["clipId"] as? String == project.clips[0].id })
        project.mergeCaption(id)
        #expect(project.annotations.count == 1)
        #expect(project.annotations[0].text == "One two three four")
        #expect(project.annotations[0].endMs == 5000)
    }

    @Test func waveformReadsRealSamplesAndFindsSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "waveform-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
            buffer.frameLength = 24000
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<24000 {
                samples[index] =
                    index >= 8000 && index < 16000 ? 0 : Float(sin(Double(index) * 0.2)) * 0.5
            }
            try file.write(from: buffer)
        }
        let result = try await VideoAudioEnvelope.read(url)
        #expect(abs(result.duration - 3) < 0.01)
        #expect(result.peaks.count >= 149)
        #expect(result.peaks[0] > 0.4)
        let quiet = try #require(result.silence().first)
        #expect(quiet.lowerBound > 0.9 && quiet.lowerBound < 1.2)
        #expect(quiet.upperBound > 1.8 && quiet.upperBound < 2.1)
    }
}
