import AVFoundation
import CoreImage
import Testing
@testable import Edith

@Suite(.timeLimit(.minutes(1))) struct VideoAudioPlanTests {
    static func fixture() async throws -> (directory: URL, project: URL, video: URL, sound: URL) {
        let directory = try VideoEditorServiceTests.folder()
        let video = try await VideoEditorServiceTests.movie(in: directory)
        let sound = directory.appendingPathComponent("tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000))
        buffer.frameLength = 192000
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<192000 {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.5
        }
        try AVAudioFile(forWriting: sound, settings: format.settings).write(from: buffer)
        let project = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic audio plan")
        return (directory, project, video, sound)
    }

    @Test func importUsesOutputClockAndReturnsAudioAliases() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: fixture.video.path, name: "intro"),
                .speed(clipID: "intro", rate: 0.5),
                .addAudio(path: fixture.sound.path, start: 1.2, offset: 0.2, name: "score"),
                .audioOptions(trackID: "score", gainDb: -6, muted: false, loop: false),
            ]), to: fixture.project, overwrite: true)
        #expect(result.audioIDs.count == 1)
        #expect(result.audioAliases["score"] == result.audioIDs)
        let project = try VideoProject.open(fixture.project)
        let track = try #require(project.audioTracks.first)
        #expect(track.startMs == 1200 && track.endMs == 2000 && track.offsetMs == 200)
        #expect(track.gainDb == -6 && track.timebase == "output")
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let audio = try #require(pipeline.composition.tracks(withMediaType: .audio).first)
        #expect(audio.segments.last?.timeMapping.target.start == CMTime(value: 6, timescale: 5))
    }

    @Test func invalidOutputStartsAndAliasCollisionsLeaveBytesUntouched() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.project)
        for start in [-1, 0.5, 0.75, Double.infinity, Double.nan] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.apply(
                    VideoEditPlan(operations: [
                        .addMedia(path: fixture.video.path, name: "intro"),
                        .speed(clipID: "intro", rate: 2),
                        .addAudio(path: fixture.sound.path, start: start, offset: 0, name: "score"),
                    ]), to: fixture.project, overwrite: true)
            }
            #expect(try Data(contentsOf: fixture.project) == original)
        }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.apply(
                VideoEditPlan(operations: [
                    .addMedia(path: fixture.video.path, name: "intro"),
                    .addAudio(path: fixture.sound.path, start: 0, offset: 0, name: "intro"),
                ]), to: fixture.project, overwrite: true)
        }
        #expect(try Data(contentsOf: fixture.project) == original)
    }

    @Test func dryRunAndGroupRemovalReturnCurrentAudioIDs() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.project)
        let operations: [VideoEditPlan.Operation] = [
            .addMedia(path: fixture.video.path, name: "intro"),
            .addAudio(path: fixture.sound.path, start: 0, offset: 0, name: "score"),
        ]
        let preview = try await VideoEditorService.apply(
            VideoEditPlan(operations: operations), to: fixture.project, dryRun: true)
        #expect(!preview.written && preview.audioIDs.count == 1)
        #expect(try Data(contentsOf: fixture.project) == original)
        let removed = try await VideoEditorService.apply(
            VideoEditPlan(operations: operations + [.removeAudio(trackID: "score")]),
            to: fixture.project, overwrite: true)
        #expect(removed.audioIDs.isEmpty && removed.audioAliases["score"] == [])
        #expect(try VideoProject.open(fixture.project).audioTracks.isEmpty)
    }

    @Test func audioSchemaRequiresAnAliasAndDescribesOutputTime() throws {
        let schema = String(decoding: try VideoEditPlan.schema(), as: UTF8.self)
        #expect(schema.contains("Rendered output seconds"))
        #expect(throws: (any Error).self) {
            try VideoEditPlan.decode(
                Data(
                    #"{"version":1,"operations":[{"addAudio":{"path":"tone.caf","start":0,"offset":0}}]}"#
                        .utf8))
        }
        let plan = VideoEditPlan(operations: [
            .addAudio(path: "tone.caf", start: 0, offset: 0, name: "score")
        ])
        #expect(try VideoEditPlan.decode(JSONEncoder().encode(plan)).operations.count == 1)
    }
}
