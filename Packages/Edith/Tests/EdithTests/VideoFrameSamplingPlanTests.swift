import AVFoundation
import Testing

@testable import Edith

@Suite(.serialized) struct VideoFrameSamplingPlanTests {
    @Test func publicPlanKeepsTrimSourceAndAudioWhileChangingDecodedFrames() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mov")
        try await VideoFrameSamplingTests.fixture(
            video, times: VideoFrameSamplingTests.timestamps("vfr"))
        let original = try Data(contentsOf: video)
        let projectURL = directory.appendingPathComponent("edit.openscreen")
        _ = try VideoEditorService.create(at: projectURL, title: "Sampling fixture")
        let added = try await VideoEditorService.apply(
            .init(operations: [
                .addMedia(path: video.path, name: "shot"),
                .videoSettings(settings: .init(width: 32, height: 32)),
                .trim(clipID: "shot", start: 2, end: 3),
            ]), to: projectURL, overwrite: true)
        let id = try #require(added.aliases["shot"])
        var project = try VideoEditorService.open(projectURL)
        let audio = directory.appendingPathComponent("score.caf")
        try Self.music(audio)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = audio.path
        project.root["assets"] = assets
        project.addAudio(audio, duration: 5, at: 0)
        try project.save(to: projectURL)
        let held = try await VideoRenderPipeline.make(project: project)
        let plan = try VideoEditPlan.decode(
            Data(
                """
                {"version":1,"operations":[{"frameSampling":{"clipID":"\(id)","mode":"nearest"}}]}
                """.utf8))
        let bytes = try Data(contentsOf: projectURL)
        _ = try await VideoEditorService.apply(plan, to: projectURL, dryRun: true)
        #expect(try Data(contentsOf: projectURL) == bytes)
        _ = try await VideoEditorService.apply(plan, to: projectURL, overwrite: true)
        let reopened = try VideoEditorService.open(projectURL)
        #expect(try reopened.clips[0].frameSampling == .nearest)
        #expect(reopened.clips[0].start == 2 && reopened.clips[0].end == 3)
        #expect(reopened.assets[0].url == video)
        #expect(try Data(contentsOf: video) == original)
        let nearest = try await VideoRenderPipeline.make(project: reopened)
        #expect(nearest.composition.duration == held.composition.duration)
        #expect(nearest.segments[0].sourceRange == held.segments[0].sourceRange)
        let before = held.composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }
        let after = nearest.composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }
        #expect(before.count == after.count && !before.isEmpty)
        for (left, right) in zip(before, after) {
            #expect(left.timeMapping.source == right.timeMapping.source)
            #expect(left.timeMapping.target == right.timeMapping.target)
        }
        #expect(
            try VideoFrameSamplingTests.read(
                nearest.composition, videoComposition: nearest.videoComposition) == Array(120..<180)
        )
        #expect(
            try VideoFrameSamplingTests.read(
                held.composition, videoComposition: held.videoComposition) == Array(119..<179))
        let delivered = try await VideoEditorService.render(
            projectURL, to: directory.appendingPathComponent("delivery.mp4"))
        #expect(delivered.videoReport?.frameCount == 60)
        #expect(
            try VideoFrameSamplingTests.read(
                AVURLAsset(url: directory.appendingPathComponent("delivery.mp4")))
                == Array(120..<180))
        #expect(try Data(contentsOf: video) == original)
        _ = try await VideoEditorService.apply(
            .init(operations: [
                .split(clipID: id, sourceTime: 2.5, rightName: "right"),
                .frameSampling(clipID: id, mode: .hold),
            ]), to: projectURL, overwrite: true)
        let mixed = try VideoEditorService.open(projectURL)
        #expect(try mixed.clips[0].frameSampling == .hold)
        #expect(try mixed.clips[1].frameSampling == .nearest)
        let mixedPipeline = try await VideoRenderPipeline.make(project: mixed)
        #expect(
            try VideoFrameSamplingTests.read(
                mixedPipeline.composition, videoComposition: mixedPipeline.videoComposition)
                == Array(119..<149) + Array(150..<180))
    }

    @Test func invalidModesAndUnavailablePhasesDoNotPublish() async throws {
        for mode in ["\"unknown\"", "null", "1", "{}"] {
            let json =
                "{\"version\":1,\"operations\":[{\"frameSampling\":{\"clipID\":\"shot\",\"mode\":\(mode)}}]}"
            #expect(throws: (any Error).self) { try VideoEditPlan.decode(Data(json.utf8)) }
        }
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mov")
        try await VideoFrameSamplingTests.fixture(
            video, times: VideoFrameSamplingTests.timestamps("oneTwenty"))
        let url = directory.appendingPathComponent("edit.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Rejection fixture")
        let added = try await VideoEditorService.apply(
            .init(operations: [
                .addMedia(path: video.path, name: "shot"), .trim(clipID: "shot", start: 2, end: 3),
            ]), to: url, overwrite: true)
        let id = try #require(added.aliases["shot"])
        let bytes = try Data(contentsOf: url)
        for mutation in [
            VideoEditPlan.Operation.trim(clipID: id, start: 4, end: 5),
            .speed(clipID: id, rate: 2),
        ] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.apply(
                    .init(operations: [
                        .frameSampling(clipID: id, mode: .nearest), mutation,
                    ]), to: url, overwrite: true)
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
        var invalid = try VideoEditorService.open(url)
        var clips = invalid.clips
        clips[0].raw["edithFrameSampling"] = "unknown"
        invalid.setClips(clips)
        #expect(throws: (any Error).self) { try VideoEditorService.validateStructure(invalid) }
        #expect(try VideoEditorService.open(url).clips[0].frameSampling == .hold)
    }

    private static func music(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for index in 0..<48000 { samples[index] = 0.05 }
        }
        for _ in 0..<5 { try writer.write(from: buffer) }
    }
}
