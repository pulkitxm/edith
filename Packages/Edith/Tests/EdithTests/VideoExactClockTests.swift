import AVFoundation
import CoreImage
import Testing
@testable import Edith

@Suite struct VideoExactClockTests {
    @Test func mixedShotLengthsKeepExactFrameAndMusicEndpoints() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("original.png")
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
            to: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 64, height: 64, frameRateNumerator: 60, frameRateDenominator: 1)
        let frames = [65, 123, 130, 131, 245, 246, 247, 260, 261, 262]
        for count in frames {
            try project.addStillAsset(
                image, duration: Double(count) / 60, metadata: VideoStillMedia.metadata(at: image))
        }
        let expectedEnd = CMTime(value: Int64(frames.reduce(0, +)), timescale: 60)
        var cursor: Int64 = 0
        for (segment, count) in zip(VideoRenderPipeline.timingSegments(project: project), frames) {
            #expect(segment.outputRange.start == CMTime(value: cursor, timescale: 60))
            cursor += Int64(count)
            #expect(segment.outputRange.end == CMTime(value: cursor, timescale: 60))
        }
        let sound = directory.appendingPathComponent("music.caf")
        try Self.music(sound, seconds: 40)
        project.addAudio(sound, duration: 40, at: 0)
        #expect(project.audioTracks.first?.outputRange.end == expectedEnd)
        let file = directory.appendingPathComponent("mixed.openscreen")
        try project.save(to: file)
        let reopened = try VideoProject.open(file)
        #expect(reopened.audioTracks.first?.outputRange.end == expectedEnd)
        let pipeline = try await VideoRenderPipeline.make(project: reopened)
        #expect(pipeline.composition.duration == expectedEnd)
        #expect(
            pipeline.composition.tracks(withMediaType: .audio).first?.timeRange.end == expectedEnd)
    }

    @Test func trimmedMuteAndDetachedAudioStayWithinExactSourceBoundaries() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mov")
        let sound = directory.appendingPathComponent("sound.caf")
        try await VideoSyntheticMovie.write(
            CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
            to: video, duration: 3, frameDuration: CMTime(value: 1, timescale: 60))
        try Self.music(sound, seconds: 3)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 64, height: 64, frameRateNumerator: 60, frameRateDenominator: 1)
        project.addAsset(video, duration: 3, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        let clipID = project.clips[0].id
        project.trim(clipID: clipID, start: 65.0 / 60, end: 130.0 / 60)
        var timeline = project.root["timeline"] as? [String: Any] ?? [:]
        timeline["muteRanges"] = [
            ["clipId": clipID, "startSec": 65.0 / 60, "endSec": 77.0 / 60]
        ]
        project.root["timeline"] = timeline
        let segment = try #require(VideoRenderPipeline.timingSegments(project: project).first)
        let mute = try #require(
            VideoAudioMix.muteIntervals(project: project, segment: segment).first)
        #expect(mute.lowerBound == .zero)
        #expect(mute.upperBound == CMTime(value: 12, timescale: 60))
        #expect(!project.detachAudio(clipID: clipID).isEmpty)
        for track in project.audioTracks {
            #expect(track.outputRange.start >= .zero)
            #expect(track.outputRange.end <= CMTime(value: 65, timescale: 60))
        }
        project.addAudio(sound, duration: 3, at: 27.0 / 48000 * 1000)
        #expect(project.audioTracks.last?.outputRange.start == CMTime(value: 27, timescale: 48000))
        let file = directory.appendingPathComponent("detached.openscreen")
        try project.save(to: file)
        _ = try await VideoEditorService.validate(file)
    }

    @Test func integralSourceFramesRemainExactAfterTrimAndSpeed() {
        for (numerator, denominator) in [(60, 1), (60000, 1001), (120, 1)] {
            var project = VideoProject.create()
            project.videoSettings = VideoSettings(
                width: 64, height: 64,
                frameRateNumerator: numerator, frameRateDenominator: denominator)
            project.addAsset(
                URL(fileURLWithPath: "/synthetic.mov"), duration: 100, width: 64, height: 64)
            let original = project.clips[0]
            let starts = [65, 123, 130, 131, 245, 246, 247, 260]
            project.setClips(
                starts.enumerated().map { index, frame in
                    var clip = original
                    clip.raw["id"] = "shot-\(index)"
                    clip.start = Double(frame * denominator) / Double(numerator)
                    clip.end = Double((frame + 130) * denominator) / Double(numerator)
                    return clip
                })
            project.root["legacyEditor"] = [
                "speedRegions": project.clips.map {
                    [
                        "clipId": $0.id, "sourceStartSec": $0.start, "sourceEndSec": $0.end,
                        "speed": 2,
                    ]
                        as [String: Any]
                }
            ]
            for (index, segment) in VideoRenderPipeline.timingSegments(project: project)
                .enumerated()
            {
                #expect(
                    segment.outputRange.start
                        == CMTime(
                            value: Int64(index * 65 * denominator), timescale: Int32(numerator)))
                #expect(
                    segment.outputRange.duration
                        == CMTime(value: Int64(65 * denominator), timescale: Int32(numerator)))
            }
        }
    }

    private static func music(_ url: URL, seconds: Int) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for index in 0..<48000 { samples[index] = channel == 0 ? 0.2 : -0.1 }
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<seconds { try writer.write(from: buffer) }
    }
}
