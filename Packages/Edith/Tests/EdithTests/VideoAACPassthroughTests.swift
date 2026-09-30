import EdithStudio
import Foundation
import Testing

@testable import Edith

@Suite(
    .enabled(
        if: StudioEnvironment.detect().ffmpeg != nil && StudioEnvironment.detect().ffprobe != nil))
struct VideoAACPassthroughTests {
    static func project(in directory: URL) async throws -> (URL, URL, String) {
        let executable = try #require(StudioEnvironment.detect().ffmpeg)
        let video = directory.appendingPathComponent("picture.mp4")
        let audio = directory.appendingPathComponent("approved.mp4")
        for (url, args) in [
            (
                video,
                [
                    "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=60", "-frames:v", "119", "-an",
                    "-c:v", "libx264", "-movie_timescale", "48000",
                ]
            ),
            (
                audio,
                [
                    "-f", "lavfi", "-i", "color=c=red:s=64x64:r=60", "-f", "lavfi", "-i",
                    "sine=frequency=440:sample_rate=48000", "-t", String(119.0 / 60), "-ac", "2",
                    "-c:a", "aac", "-c:v", "libx264", "-movie_timescale", "48000",
                ]
            ),
        ] {
            let result = try await StudioProcess.run(
                executable, ["-v", "error"] + args + [url.path])
            #expect(result.status == 0, "\(result.errorTail)")
        }
        let project = directory.appendingPathComponent("demo.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic AAC copy")
        let result = try await VideoEditorService.apply(
            .init(operations: [
                .videoSettings(settings: .init(width: 64, height: 64)),
                .addMedia(path: video.path, name: "picture"),
                .addAudio(path: audio.path, start: 0, offset: 0, name: "score"),
            ]), to: project, overwrite: true)
        return (project, audio, try #require(result.audioAliases["score"]?.first))
    }

    @Test(arguments: [VideoDeliverySettings.Codec.h264, .proRes422])
    func fullStreamPreservesPrimingTrailingTrimAndDecodedAudio(_ codec: VideoDeliverySettings.Codec)
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (project, audio, trackID) = try await Self.project(in: directory)
        let original = try StudioAudioMastering.sha256(audio)
        var settings = VideoDeliverySettings()
        settings.codec = codec
        settings.audioCodec = .copy
        settings.audioCopyTrackID = trackID
        let output = directory.appendingPathComponent("delivery.\(codec.fileExtension)")
        let rendered = try await VideoEditorService.render(project, to: output, settings: settings)
        let report = try #require(rendered.videoReport?.audioPassthrough)
        #expect(report.packetDataAndTimingVerified)
        #expect(report.packetCount == 94)
        #expect(rendered.videoReport?.frameCount == 119)
        let before = try await VideoAACPassthrough.probe(audio, environment: .detect())
        let after = try await VideoAACPassthrough.probe(output, environment: .detect())
        #expect(before.packets == after.packets)
        #expect(before.streams.first?.duration_ts == 95_200)
        #expect(after.streams.first?.duration_ts == 95_200)
        #expect(before.packets.first?.pts == -1024)
        #expect(before.packets.last?.duration == 992)
        #expect(try StudioAudioMastering.sha256(audio) == original)
        let executable = try #require(StudioEnvironment.detect().ffmpeg)
        var decoded: [String] = []
        for source in [audio, output] {
            let result = try await StudioProcess.run(
                executable,
                [
                    "-v", "error", "-i", source.path,
                    "-map", "0:a:0", "-c:a", "pcm_s24le", "-f", "hash", "-hash", "sha256", "-",
                ])
            #expect(result.status == 0)
            decoded.append(result.output)
        }
        #expect(decoded[0] == decoded[1])
    }

    @Test func editsAmbiguityResamplingAndPartialRangesFailBeforeOutputs() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, _, id) = try await Self.project(in: directory)
        let project = try VideoEditorService.open(url)
        var settings = VideoDeliverySettings()
        settings.audioCodec = .copy
        settings.audioCopyTrackID = id
        let changes: [[String: Any]] = [
            ["gainDb": 1], ["offsetMs": 1], ["startMs": 1.0], ["fadeInMs": 1],
            ["fadeOutMs": 1], ["loop": true], ["rate": 1.01],
            ["gainEnvelope": []], ["muted": true], ["endMs": 1900.0],
        ]
        for change in changes {
            var invalid = project
            invalid.editRegion("audioTracks", id: id) {
                for (key, value) in change { $0[key] = value }
                if change["startMs"] != nil || change["endMs"] != nil {
                    $0.removeValue(forKey: "outputRange")
                }
            }
            do {
                _ = try await VideoAACPassthrough.prepare(invalid, settings: settings, range: nil)
                Issue.record("Invalid audio options accepted: \(change)")
            } catch let error as VideoEditorService.Failure {
                #expect(error.code == "invalid_audio_copy")
            }
        }
        var mix = project
        var duplicate = project.audioTracks[0].raw
        duplicate["id"] = "second"
        mix.root["audioTracks"] = project.audioTracks.map(\.raw) + [duplicate]
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoAACPassthrough.prepare(mix, settings: settings, range: nil)
        }
        settings.audioSampleRate = 44100
        let destination = directory.appendingPathComponent("rejected.mp4")
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoEditorService.render(url, to: destination, settings: settings)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        settings.audioSampleRate = 48000
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoEditorService.render(
                url, to: destination, settings: settings,
                range: .init(startFrame: 0, endFrame: 118))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        var attached = project
        var clips = attached.clips
        clips[0].raw["assetId"] = project.audioTracks[0].assetID
        attached.setClips(clips)
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoAACPassthrough.prepare(attached, settings: settings, range: nil)
        }
        let ambiguous = directory.appendingPathComponent("ambiguous.mp4")
        let executable = try #require(StudioEnvironment.detect().ffmpeg)
        let approved = try #require(
            project.assets.first { $0.id == project.audioTracks[0].assetID })
        let mux = try await StudioProcess.run(
            executable,
            [
                "-v", "error", "-i", approved.audioURL.path,
                "-map", "0:v:0", "-map", "0:a:0", "-map", "0:a:0", "-c", "copy", ambiguous.path,
            ])
        #expect(mux.status == 0)
        var multipleStreams = project
        multipleStreams.root["assets"] = project.assets.map {
            var raw = $0.raw
            if $0.id == approved.id { raw["originalPath"] = ambiguous.path }
            return raw
        }
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoAACPassthrough.prepare(multipleStreams, settings: settings, range: nil)
        }
    }
}
