import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Testing
@testable import StudioExtension

@Suite(.timeLimit(.minutes(1))) struct VideoAudioPlanTests {
    @Test func detachedGroupsPreserveNativeSamplesAndSupportTimingEdits() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: fixture.video.path, name: "intro")
            ]), to: fixture.project, overwrite: true)
        var source = try VideoProject.open(fixture.project)
        var assets = source.assets.map(\.raw)
        assets[0]["edithAudioPath"] = fixture.sound.path
        source.root["assets"] = assets
        let clipID = source.clips[0].id
        source.addSpeed(startMs: 0, endMs: 500, rate: 0.5)
        source.addSpeed(startMs: 500, endMs: 1000, rate: 2)
        source.setClipAudio(clipID: clipID, gain: -6)
        try source.save(to: fixture.project)
        let before = try await VideoRenderPipeline.make(project: source)
        let detached = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .detachAudio(clipID: clipID, name: "voice")
            ]), to: fixture.project, overwrite: true)
        let snapshot = try VideoProject.open(fixture.project)
        #expect(detached.audioAliases["voice"] == detached.audioIDs)
        #expect(detached.audioIDs.count == 2)
        #expect(snapshot.clips[0].raw["audioMuted"] as? Bool == true)
        #expect(snapshot.audioTracks.map(\.outputRange) == before.segments.map(\.outputRange))
        #expect(snapshot.audioTracks.map(\.rate) == [0.5, 2])
        let after = try await VideoRenderPipeline.make(project: snapshot)
        #expect(try Self.samples(before) == Self.samples(after))
        var restored = try VideoProject.open(fixture.project)
        restored.root = source.root
        try restored.save(to: fixture.project)
        let edited = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .detachAudio(clipID: clipID, name: "voice"),
                .audioFades(trackID: "voice", fadeIn: 0.2, fadeOut: 0.2),
                .splitAudio(trackID: "voice", time: 1, rightName: "tail"),
                .trimAudio(trackID: "voice", start: 0.1, end: 0.9),
                .moveAudio(trackID: "voice", start: 0),
                .audioOptions(trackID: "voice", gainDb: -9, muted: false, loop: false),
                .removeAudio(trackID: "tail"),
            ]), to: fixture.project, overwrite: true)
        #expect(edited.audioIDs.count == 1)
        #expect(edited.audioAliases["tail"] == [])
        #expect(edited.audioAliases["voice"] == edited.audioIDs)
        let saved = try VideoProject.open(fixture.project)
        let track = try #require(saved.audioTracks.first)
        #expect(
            track.outputRange == CMTimeRange(start: .zero, duration: CMTime(value: 4, timescale: 5))
        )
        #expect(abs(track.offsetMs - 50) < 0.001)
        #expect(track.rate == 0.5 && track.gainDb == -9)
        #expect(abs(VideoAudioAutomation.track(track).value(at: 0) - 0.5) < 0.001)
        #expect(VideoAudioAutomation.track(track).value(at: 0.3) == 1)
        #expect(track.raw["gainEnvelope"] != nil)
        _ = try await VideoRenderPipeline.make(project: saved)
    }

    @Test func splittingFadesPreservesSamplesAndOneEndEditsPreserveTheOther() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let imported = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: fixture.video.path, name: "intro"),
                .speed(clipID: "intro", rate: 0.25),
                .addAudio(path: fixture.sound.path, start: 0, offset: 0, name: "score"),
                .audioFades(trackID: "score", fadeIn: 2, fadeOut: 2),
            ]), to: fixture.project, overwrite: true)
        let id = try #require(imported.audioIDs.first)
        let original = try VideoProject.open(fixture.project)
        let before = try await VideoRenderPipeline.make(project: original)
        let split = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .splitAudio(trackID: id, time: 3, rightName: "tail")
            ]), to: fixture.project, overwrite: true)
        let divided = try VideoProject.open(fixture.project)
        let after = try await VideoRenderPipeline.make(project: divided)
        let first = try Self.samples(before)
        let second = try Self.samples(after)
        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(split.audioAliases["tail"]?.count == 1)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .audioFades(trackID: id, fadeIn: 0.5, fadeOut: nil)
            ]), to: fixture.project, overwrite: true)
        let changed = try VideoProject.open(fixture.project)
        let left = try #require(changed.audioTracks.first { $0.id == id })
        let envelope = VideoAudioAutomation.track(left)
        #expect(envelope.value(at: 1) == 1)
        #expect(envelope.value(at: 2.5) == 0.75)
        #expect(left.fadeInMs == 500)
    }

    @Test func splitAliasesSelectTheirOwnSideAndTrimPreservesLoopOffsets() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: fixture.video.path, name: "intro"),
                .speed(clipID: "intro", rate: 0.25),
                .addAudio(path: fixture.sound.path, start: 0, offset: 0, name: "score"),
                .audioOptions(trackID: "score", gainDb: 0, muted: false, loop: true),
                .splitAudio(trackID: "score", time: 2, rightName: "tail"),
                .audioOptions(trackID: "score", gainDb: -6, muted: true, loop: true),
                .trimAudio(trackID: "tail", start: 2.5, end: 3.5),
                .moveAudio(trackID: "tail", start: 2),
                .audioFades(trackID: "tail", fadeIn: 99, fadeOut: 0.2),
                .audioFades(trackID: "tail", fadeIn: 0, fadeOut: nil),
            ]), to: fixture.project, overwrite: true)
        let project = try VideoProject.open(fixture.project)
        let left = try #require(
            project.audioTracks.first { result.audioAliases["score"]?.contains($0.id) == true })
        let right = try #require(
            project.audioTracks.first { result.audioAliases["tail"]?.contains($0.id) == true })
        #expect(result.audioIDs.count == 2)
        #expect(left.muted && left.gainDb == -6 && left.endMs == 2000)
        #expect(!right.muted && right.gainDb == 0 && right.loop)
        #expect(right.startMs == 2000 && right.endMs == 3000 && right.offsetMs == 2500)
        #expect(right.fadeInMs == 0 && abs(right.fadeOutMs - 200) < 0.001)
        let envelope = VideoAudioAutomation.track(right)
        #expect(envelope.value(at: 0) == 1)
        #expect(abs(envelope.value(at: 0.9) - 0.5) < 0.001)
    }

    @Test func invalidTimingAndDetachOperationsAreAtomic() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.project)
        let prefix: [VideoEditPlan.Operation] = [
            .addMedia(path: fixture.video.path, name: "intro"),
            .addAudio(path: fixture.sound.path, start: 0, offset: 0, name: "score"),
        ]
        let invalid: [VideoEditPlan.Operation] = [
            .detachAudio(clipID: "intro", name: "silent"),
            .moveAudio(trackID: "score", start: 0.1),
            .moveAudio(trackID: "score", start: .greatestFiniteMagnitude),
            .splitAudio(trackID: "score", time: 0, rightName: "tail"),
            .splitAudio(trackID: "score", time: 1, rightName: "tail"),
            .splitAudio(trackID: "score", time: 0.5, rightName: "intro"),
            .trimAudio(trackID: "score", start: 0.8, end: 0.4),
            .trimAudio(trackID: "score", start: 0, end: 2),
            .audioFades(trackID: "score", fadeIn: -1, fadeOut: nil),
            .audioFades(trackID: "score", fadeIn: nil, fadeOut: nil),
            .audioOptions(trackID: "missing", gainDb: 0, muted: false, loop: false),
        ]
        for operation in invalid {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.apply(
                    VideoEditPlan(operations: prefix + [operation]),
                    to: fixture.project, overwrite: true)
            }
            #expect(try Data(contentsOf: fixture.project) == original)
        }
    }

    @Test func strictAudioEditingSchemaRejectsMissingUnknownAndNullFields() throws {
        for operation in [
            #"{"detachAudio":{"clipID":"intro"}}"#,
            #"{"moveAudio":{"trackID":"score","start":0,"end":1}}"#,
            #"{"splitAudio":{"trackID":"score","time":1}}"#,
            #"{"trimAudio":{"trackID":"score","start":0}}"#,
            #"{"audioFades":{"trackID":"score"}}"#,
            #"{"audioFades":{"trackID":"score","fadeIn":null}}"#,
            #"{"audioFades":{"trackID":"score","fadeIn":1,"fadeOutMs":2}}"#,
        ] {
            #expect(throws: (any Error).self) {
                try VideoEditPlan.decode(Data("{\"version\":1,\"operations\":[\(operation)]}".utf8))
            }
        }
        let plan = VideoEditPlan(operations: [
            .detachAudio(clipID: "intro", name: "voice"),
            .moveAudio(trackID: "voice", start: 0),
            .splitAudio(trackID: "voice", time: 1, rightName: "tail"),
            .trimAudio(trackID: "tail", start: 1, end: 2),
            .audioFades(trackID: "tail", fadeIn: nil, fadeOut: 0.2),
        ])
        #expect(try VideoEditPlan.decode(JSONEncoder().encode(plan)).operations.count == 5)
    }

    static func samples(_ pipeline: VideoRenderPipeline) throws -> [Float] {
        let reader = try AVAssetReader(asset: pipeline.composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: pipeline.composition.tracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        output.audioMix = pipeline.audioMix
        reader.add(output)
        try #require(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var buffer = [Float](repeating: 0, count: count)
            let status = buffer.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            samples.append(contentsOf: buffer)
        }
        try #require(reader.status == .completed)
        return samples
    }

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
